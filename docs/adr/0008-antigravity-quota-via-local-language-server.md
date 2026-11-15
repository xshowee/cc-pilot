# Antigravity 只显示额度，经桌面 App 的本地接口读取，多账号靠快照

cc-pilot 显示 Antigravity 桌面 App 里 Google 账号的额度，但不把它做成工具：没有档案、不能切换、没有实时额度，同 Kimi Code（ADR 0007）。与 Kimi Code 不同，cc-pilot 不读取、不保存 Google 凭据：用户刷新时，cc-pilot 找到 App 正在运行的 language server（名字为 `language_server`、可执行文件在 `Antigravity.app` 包内的进程），从它的启动参数里取 `--csrf_token` 的值，用 libproc / sysctl 列出它的 TCP 监听端口，对 `127.0.0.1` 的各端口逐个用明文 HTTP 调本地 RPC `GetUserStatus`，取第一个返回 200 的端口，再在同一端口调 `RetrieveUserQuotaSummary`（`{"forceRefresh": true}`）。前者给出当前登录账号的邮箱和套餐，后者给出各组额度。账号由用户手动添加（输入邮箱）；App 同一时刻只登录一个账号，所以每个添加的邮箱最后一次读到的结果作为快照存在本机。

## Considered Options

- **用 App 的 token 直接请求 Google 的额度接口**：不经 App 的本地接口。没有采用：实测以如实标明的 User-Agent 请求 `retrieveUserQuotaSummary` 返回 403 `SUBSCRIPTION_REQUIRED`；要拿到数字就得冒充官方客户端，还要读 Google 凭据并自行续期，违背 ADR 0001（凭据只读、不续期）和 ADR 0007（不冒充官方客户端）。
- **依赖 `agy` 命令行**（`agy -p "/usage"`，或经 ACP 取套餐）：没有采用：用户不想依赖它；`agy` 与 App 共用登录代码，但它和 App 是否共用同一个登录状态没有查清，读到的未必是 App 里的账号。也不作为后备。
- **读 `GetUserStatus` 里各模型的 `quotaInfo`**：只用一个 RPC。没有采用：它只有 5 小时窗口，而且比 `RetrieveUserQuotaSummary` 滞后；周窗口只在后者里。
- **读到新邮箱就自动出现，不用手动添加**：最初的做法（"刷新全部"在没有卡片时也读一次，第一张卡片只能这样产生）。2026-11-15 改为手动添加：用户先添加、等于先同意，cc-pilot 才去读别的 App 的进程参数；与 Kimi Code 一样由用户添加；也不会冒出用户不想看的账号。
- **做成带档案和切换的工具**：没有采用：用户只要额度；切换 Google 账号是在 App 里先退出、再登录，cc-pilot 没有可切换的对象。

## Consequences

- 一次刷新会让 App 以它自己的身份向 Google 查询一次：`RetrieveUserQuotaSummary` 的数值比 `GetUserStatus` 新，`forceRefresh` 还绕过了 language server 自己的缓存（据 antigravity-usage-monitor 插件的注释，不带它时约有 3 分钟缓存）。cc-pilot 自己不联系 Google，请求只发到本机。所以只在用户点某张 Antigravity 卡片的刷新或"刷新全部"时进行，不在后台轮询；启动 App、打开面板、添加账号都不读。没有添加任何 Antigravity 账号时，"刷新全部"不读 Antigravity；它的可用条件是有可刷新的 Claude Code / ChatGPT / Kimi Code 账号或者有 Antigravity 账号，并且没有刷新在进行。
- csrf token 是从别的进程参数里读到的机密：只取 `--csrf_token` 的值，只在本次刷新期间放在内存里，不落盘，也不进结果、失败原因和日志。同一组参数里的 `--host_bridge_token` 不读。参数有空格和等号两种写法（实测 `--csrf_token <token>`、`--host_bridge_url=…`），解析两种都要支持。
- 端口：实测 language server 监听三个随机端口，对第一个发明文 HTTP 立刻得到 400（它是 HTTPS 端口），第二个返回 200，第三个没试。cc-pilot 不走 HTTPS、不接受自签名证书；每次探测设短超时，免得某个端口拖住刷新。开着多个窗口、有多个 language server 时，逐个进程尝试，取第一个能拿到 200 的。
- 读取的字段只有：`GetUserStatus` 的 `userStatus.email`、`userTier.name`（套餐标签）与 `userTier.id`；`RetrieveUserQuotaSummary` 各组的 `displayName`、`description` 和各桶的 `bucketId`、`displayName`、`window`、`remainingFraction`、`resetTime`、`disabled`（为 `true` 时当作剩余 0%，同 antigravity-usage-monitor 插件）。姓名、头像、旧的 `planInfo` 等不读、不存。没有 `email` 就是 App 里没有登录。
- 组和桶按接口返回的原样显示，不写死组数，也不假设每组正好一个 5 小时窗口和一个周窗口：组按接口顺序；同一组里 5 小时窗口排在周窗口前（接口给的是周窗口在前，但 Claude Code、Kimi Code 卡片都是 5 小时窗口在前），同类窗口之间保持接口顺序。antigravity-usage-monitor 插件的手写夹具（不是实测）里，Google AI Pro 有只含周窗口的独立组，也有一组里两个周窗口的。同一组里同一窗口类型出现多次时，第二个起的行用桶自己的名称区分。组名按组的 `displayName` 认（`Gemini Models` 显示"Gemini 模型"，`Claude and GPT models` 显示"Claude 和 GPT 模型"），不按 `bucketId` 前缀：Pro 的 Argon 组的 `bucketId` 是 `gemini-argon-wtu-weekly`，按前缀会被错认成 Gemini 模型组。其余组照搬接口原名。
- 接口用 proto3，零值字段会被省略：`remainingFraction` 缺失而 `resetTime` 是未来时间就是剩余 0%；两者都缺就没有数字。`window` 不是 `5h` 或 `weekly`、或者没有 `groups`，就提示"接口可能已变化"，不猜。
- 快照：每个添加的邮箱一条（邮箱、套餐、各组各窗口的剩余与重置时间、组内模型列表、读取时间），另记最后一次成功读到的邮箱。邮箱的匹配不分大小写，卡片保持添加时的写法；添加后还没读到过的卡片只有邮箱和刷新按钮，显示"尚未读取"。成功的结果直接替换这个邮箱的旧快照，不合并。读到没添加的邮箱不建卡片、不存它的数据，但仍记为最后读到（所以已添加的卡片全部变灰、没有"当前"）。最后读到的账号标为"当前"（同当前档案的标记和底色，表示 App 最后一次读到时登录的是它），其他账号整体变灰并标明读取时间；快照里已过重置时间的窗口显示"已重置，待刷新"。读到的邮箱与被点的卡片不同时，被点的卡片短暂提示 App 里登录的是哪个邮箱。App 没开时刷新不算失败，卡片保持快照。
- 快照存在 cc-pilot 的应用数据目录（与 Token 用量账本同处）的一个 JSON 文件里，不含任何凭据；启动时读入，每次成功刷新、添加、删除后写回，读不出就当作没有快照。格式无法识别时丢掉这个邮箱的数据，但卡片留着并存下一条没有数据的记录，重启后仍显示"接口可能已变化"，直到这个邮箱下次读取成功；这条记录与"添加后还没读到过"的记录带不同的标记（文件版本 3；版本 2 里没有数据的都是格式无法识别，版本 2 文件里的账号都当作已添加）。删除卡片会一起删掉快照；之后再读到同一邮箱也不会重新出现，要再手动添加。
- Antigravity 不在 `Tool` 里，菜单栏、Token 用量都没有它；有统计面板，但只放账号和额度。
- 依赖的是没有文档的内部接口：进程名、参数名、RPC 路径（`/exa.language_server_pb.LanguageServerService/<方法>`）、`X-Codeium-Csrf-Token` 请求头和响应格式，都按 2026-11-14 Antigravity 2.32.1、Google AI Ultra 账号的实测实现。App 升级后要重新验证；格式变了就提示"接口可能已变化"，而不是显示错的数字。
