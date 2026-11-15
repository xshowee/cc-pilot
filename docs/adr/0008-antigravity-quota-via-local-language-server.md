# Antigravity 非工具定位，经桌面 App 本地接口读取额度与轨迹用量，多账号靠快照

cc-pilot 显示 Antigravity 桌面 App 里 Google 账号的额度与按邮箱隔离的 Token 用量，但不把它做成工具：没有档案、不能切换、不在 `enum Tool` 中，也不显示在顶部 macOS 菜单栏（同 Kimi Code 的非工具定位，ADR 0007）。与 Kimi Code 不同，cc-pilot 不读取、不保存 Google 凭据：只面向 `Antigravity.app` 桌面端运行实例，找到正在运行的 language server（名字为 `language_server`、可执行文件在 `Antigravity.app` 包内的进程），从它的启动参数里取 `--csrf_token` 的值，用 libproc / sysctl 列出它的 TCP 监听端口，对 `127.0.0.1` 的各端口逐个用明文 HTTP 调本地 Connect RPC（`/exa.language_server_pb.LanguageServerService/<方法>`）。`GetUserStatus` 给出当前登录账号的邮箱、套餐与动态模型映射表，`RetrieveUserQuotaSummary` 给出各组额度，`GetAllCascadeTrajectories` 与 `GetCascadeTrajectory` 给出桌面端对话轨迹步骤的 Token 与生成耗时。账号由用户手动添加（输入邮箱）；App 同一时刻只登录一个账号，所以每个添加的邮箱最后一次读到的额度快照存在本机 JSON 文件中，各邮箱的 Token 账本与对话归属映射则写入共用的 `token-usage.sqlite`。

## Considered Options

- **用 App 的 token 直接请求 Google 的额度接口**：不经 App 的本地接口。没有采用：实测以如实标明的 User-Agent 请求 `retrieveUserQuotaSummary` 返回 403 `SUBSCRIPTION_REQUIRED`；要拿到数字就得冒充官方客户端，还要读 Google 凭据并自行续期，违背 ADR 0001（凭据只读、不续期）和 ADR 0007（不冒充官方客户端）。
- **依赖 `agy` 命令行**（`agy -p "/usage"`，或经 ACP 取套餐）：没有采用：用户不想依赖它；`agy` 与 App 共用登录代码，但它和 App 是否共用同一个登录状态没有查清，读到的未必是 App 里的账号。也不作为后备，也不接入 Antigravity CLI 或第三方 IDE 插件的会话。
- **直接解析本地离线 `transcript_full.jsonl` 或对话 SQLite 库**：没有采用。2026-11-15 实测确认桌面端 `transcript_full.jsonl` 缺少 `model` 字段，本地对话元数据也不包含所属用户邮箱；脱离运行中的 `language_server` 回填离线记录只会产生模型未知或跨账号错配的占位数据。
- **读 `GetUserStatus` 里各模型的 `quotaInfo`**：只用一个 RPC。没有采用：它只有 5 小时窗口，而且比 `RetrieveUserQuotaSummary` 滞后；周窗口只在后者里。
- **读到新邮箱就自动出现，不用手动添加**：最初的做法（"刷新全部"在没有卡片时也读一次，第一张卡片只能这样产生）。2026-11-15 改为手动添加：用户先添加、等于先同意，cc-pilot 才去监听桌面端对话目录并读取别的 App 的进程参数；与 Kimi Code 一样由用户添加；也不会冒出用户不想看的账号。
- **做成带档案和切换的工具**：没有采用：用户只要查看额度与用量；切换 Google 账号是在 App 里先退出、再登录，cc-pilot 没有可切换的对象。

## Consequences

- **授权门控（`!AntigravityBoard.emails.isEmpty`）与零空闲轮询**：cc-pilot 启动时及每次添加/删除 Antigravity 卡片后检查看板是否存在手动添加的邮箱。只要没有卡片（`emails` 为空），就绝不启动 `<HOME>/.gemini/antigravity/conversations` 的 FSEvents 监听、绝不扫描 `language_server` 进程参数、绝不发起任何被动本地 RPC；一旦添加第一张卡片立即开启监听，移除最后一张卡片立即销毁 FSEvents 流、取消待执行防抖并清空缓存的进程句柄、轨迹水位线与内存实时速度。全部轨迹采集与被动额度更新仅由对话目录 FSEvents 经 trailing-edge 防抖（默认 0.5 秒）触发，没有任何后台定时轮询循环，也不触碰 Antigravity CLI 或 IDE 插件。
- **手动刷新与被动额度更新的真实网络边界**：
  - 手动刷新（点击卡片刷新按钮或"刷新全部"）仍调用 `RetrieveUserQuotaSummary` 并携带 `{"forceRefresh": true}`，绕过 `language_server` 约 3 分钟的内部缓存，使桌面 App 以其自身身份向 Google 查询一次（失败时提示错误，格式不可识别时置 `.discarded`；没有卡片时"刷新全部"不读 Antigravity）。
  - 被动额度更新仅在对话目录 FSEvents 触发活跃同步且 `GetUserStatus` 已登录时运行，严格遵守 180 秒（3 分钟）冷却，并在发起请求前更新尝试时间戳防止失败重试风暴；请求 `RetrieveUserQuotaSummary` 时发送空体 `{}`（**不带 `forceRefresh`**）到 `127.0.0.1`，以优先命中 `language_server` 约 3 分钟的本地缓存。**但必须如实指出：若在持续对话期间 `language_server` 自身的本地缓存已过期，该被动请求仍会使桌面 App 以最多每 3 分钟一次的频率向 Google 发起上游查询；在没有卡片或桌面端无对话活动（空闲）时，产生零本地 RPC 与零上游流量。**
  - 被动通道通过 `AntigravityBoard.recordPassive` 仅消费成功解析的响应：已添加邮箱更新快照与 `lastReadEmail` 并清除旧错误；未添加邮箱只更新 `lastReadEmail`（不建卡片、不存额度快照，使已有卡片正确灰显为非当前账号）；网络失败、非 200 或格式不可识别一律静默忽略并保留现有快照，绝不触发 `.discarded` 或错误提示。
- **进程探测、缓存与 `--csrf_token` 机密边界**：仅从 `Antigravity.app` 包内 `language_server` 进程的启动参数读取 `--csrf_token`（兼容空格与等号两种写法），同一组参数里的 `--host_bridge_token` 等不读；token 只保存在内存里，不落盘，也不进结果、失败原因和日志。监听的 `AntigravityTrajectoryCollector` 在内存中缓存 `(server, port, csrfToken)` 句柄，稳态对话事件直接复用该句柄，仅在无缓存或 RPC 传输失败/非 200 时重扫进程。实测 `language_server` 监听三个随机端口，第一个收明文 HTTP 立刻返回 400（HTTPS 端口），第二个返回 200；cc-pilot 不走 HTTPS、不接受自签名证书，每次探测设短超时，多进程时取第一个返回 200 的进程和端口。
- **本地轨迹采集、截断防护与模型归一化**：
  - 每次防抖同步先调 `GetUserStatus`（取在线邮箱与 `cascadeModelConfigData.clientModelConfigs`）和 `GetAllCascadeTrajectories`（`{}`），在内存中按每个 `cascadeId` 的 `(stepCount, lastModifiedTime)` 签名比对水位线，只对签名变化的轨迹及其关联子代理调用 `GetCascadeTrajectory`（`{"cascadeId": ...}`）。
  - 若 `GetCascadeTrajectory` 返回的 `numTotalSteps` 大于已返回的 `steps.count`，视为未完全落盘的截断响应，整条跳过且不推进水位线，留待后续事件重试；仅提取 `status == "CORTEX_STEP_STATUS_DONE"` 且非零用量的步骤。
  - 从 `metadata.modelUsage`（缺失时回退 `retryInfos[0].usage`，不累加）提取 `inputTokens`、`outputTokens`（已包含思考 token）和 `cacheReadTokens`，`cacheWrite` 固定写 `0`；入账前结合 `clientModelConfigs`（`modelOrAlias.model`）、步骤 `chat.responseModel` 与内置静态映射将 `MODEL_PLACEHOLDER_*` / `MODEL_*` 归一化为规范模型 ID（无法解析时原样保留）。
- **严格按邮箱隔离的账本归因与离线历史边界**：
  - 复用共用账本 `~/Library/Application Support/cc-pilot/token-usage.sqlite`（保持 `PRAGMA user_version = 5` 与 `enum Tool` 不变），在 `TokenLedger+Antigravity.swift` 中懒建辅助表 `antigravity_sessions` 记录会话绑定与子代理归属，`messages.tool` 写入字面量 `"antigravity"`，以 `"antigravity:<cascadeId>:<stepIndex>"` 幂等去重并沿用既有的按天汇总和保留期清理策略。
  - 尚未绑定过邮箱的对话，只有步骤完成时间不早于 `listenerStartedAt - 30s`（30 秒时钟容差）才绑定当前在线邮箱（`"antigravity:<lowercased-email>"`）；更早离线完成的历史步骤一律记为 `unattributed`（`attribution = 2`），绝不因切号或重开监听而跨账号归因。已登录但未手动添加到看板的邮箱仍将其步骤记入其邮箱名下账本（供后续添加卡片时立即可用），但绝不自动建卡片或存额度快照。
- **额度字段、窗口对齐、静态算费与内存实时速度**：
  - 读取与显示字段仍严格收敛：`GetUserStatus` 仅取 `email`、`userTier.name`/`id` 与模型配置；`RetrieveUserQuotaSummary` 各组与桶按接口原样顺序、5 小时在前周窗口在后展示，遵守 proto3 零值规则与组名识别（`Gemini Models` / `Claude and GPT models` / 原名）。姓名、头像、旧 `planInfo` 与对话正文均不读取、不保存。
  - 统计面板（320pt 悬停浮窗）展示隐藏 `Cache Write` 的 3 类 Token 用量、`5 小时窗口` / `周窗口`（按 `Gemini -> Argon -> Carbon -> Claude & GPT` 池优先级挑选首个有效 `resetTime` 对齐，缺失时回退滚动 5 小时 / 7 天）、`累计 Token 用量`、按邮箱清空及全局清空；按随版内置静态定价目录在查询期计算等效 API 美元费用与缓存节省（SQLite 不新增费用列；未收录模型保留 Token 统计并附提示，不伪造 `$0`）；并在内存中为当前在线活跃账号最近一条含子代理根对话计算实时生成速度（`tok/s`、`TTFT`、会话均值，过滤 `CHECKPOINT` 压缩步及耗时 `< 0.5s`、输出 `< 50`、`TTFT` 越界样本；不落盘，在桌面端离线、查看旧快照或无有效样本时隐藏）。
- **快照持久化与版本兼容性**：快照存在 `~/Library/Application Support/cc-pilot/antigravity-snapshots.json`（不含凭据）；启动时读入，成功刷新、被动更新命中已添加邮箱、添加、删除后写回。格式无法识别时仅在手动刷新丢掉数据并标记 `.discarded`（显示"接口可能已变化"，版本 3 区分于"尚未读取"；删除卡片即一起删掉快照）。依赖的进程名、参数名、RPC 路径、请求头与响应格式按 2026-11-14 Antigravity 2.32.1（Google AI Ultra）实测实现，App 升级后需重新验证。
