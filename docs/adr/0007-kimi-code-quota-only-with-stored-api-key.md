# Kimi Code 只显示额度，API key 由 cc-pilot 保存在钥匙串

cc-pilot 显示 Kimi Code 的额度，但不把它做成第三个工具：没有档案、不能切换、没有实时额度。额度用用户在 Kimi Code 控制台创建的 API key 请求 `https://api.kimi.com/coding/v1/usages` 获取；一个 Kimi Code 账号是用户起的名称加一个 key，可以有多个；添加入口与另外两个工具相同（面板的"添加账号…"里选 Kimi Code），只是不打开终端登录，而是直接填 key，保存在登录钥匙串里 cc-pilot 自己的项中。这是 cc-pilot 唯一自己保存的凭据——Claude Code 和 ChatGPT 的凭据仍然只读、从不写入。

## Considered Options

- **读 Kimi Code CLI 的登录凭据**（`~/.kimi-code/credentials/`）：与另外两个工具的做法一致，不用保存任何东西。没有采用：凭据约 15 分钟过期，而 cc-pilot 不续期；请求还要带上与官方客户端相同的设备标识头，违背"如实标明 cc-pilot、不冒充官方客户端"；没装 CLI 的用户完全用不了。
- **读浏览器里 kimi.com 的 Cookie**：没有采用：要完全磁盘访问权限，且网络层按约定不存、不带 Cookie。
- **做成带档案和切换的第三个工具**：没有采用：用户只要额度；Kimi Code 的所有设备和 API key 共用同一份额度，没有可切换的对象。

## Consequences

- 钥匙串不再是纯只读：每个 Kimi Code 账号多一项 `cc-pilot Kimi Code API key`（account 是账号名称），用 Security 框架读写（不经 `/usr/bin/security`，免得 key 出现在命令行参数里）。检查程序通过 `CoreEnvironment.kimiKeys` 换成内存里的假实现。
- 接口是实验性的、没有官方文档。只读实测过的 `usages.limit_5h` / `limit_7d`；其余字段含义因套餐而异，不读、不猜，格式变了就提示"接口可能已变化"。
- 额度响应里没有邮箱和套餐。额度按用户起的名称记，两个 key 属于同一个 Kimi 账户时也各显示各的；删除账号时必须丢掉旧数字（同名可能再加另一个 key）。2026-11-11 起，刷新时紧跟额度请求再请求 `GET /coding/v1/me`，规则同模型列表。它只读 `user_level_name` 和 `user_id`：前者作为卡片上的套餐标签，后者用来标注"与某某是同一账号"。同一账户的额度不合并，仍然各显示各的。响应里的昵称、手机号等个人信息不读、不存。结果只在内存里，所以要刷新过才能认出同一账户。
- 卡片上可以复制 API key（2026-11-10 用户要求）：key 会离开钥匙串，所以写剪贴板时只留本机（不经通用剪贴板同步）、标记为机密和临时（nspasteboard.org 的约定，剪贴板管理工具不记历史），一分钟后或 App 退出时，剪贴板还是这次写入的内容就清空，被用户别的复制覆盖了就不动（`SecretClipboard`）。
- 删除不经 `ccp`：在面板里确认后直接从钥匙串移除 key。没有"更换 key"，删除后重新添加。
- Kimi Code 不在 `Tool` 里（添加表单为此另有一个只在界面用的选择项），菜单栏、统计面板、Token 用量都没有它。
- 鼠标停在 Kimi Code 卡片上时显示 Base URL 和可用模型列表（2026-11-11 用户要求）。这仍然不是第三个工具：没有档案、不能切换。它借用统计面板的窗口，但显示的不是统计：侧边面板的行多了一种不属于 `Tool` 的 Kimi 行。Base URL 是固定值：Anthropic 兼容的 `https://api.kimi.com/coding/` 和 OpenAI 兼容的 `https://api.kimi.com/coding/v1`，2026-11-11 不带 key 实测这两个地址下的接口返回 401。模型列表用同一个 key 请求 `GET /coding/v1/models`，同样没有官方文档，同样只在用户刷新这个账号时紧跟额度请求发出。key 只读一次；额度请求被拒、被限流或网络不通时不请求。列表只放在内存里，失败时保留上一次的。只读 `id`、`display_name`、`context_length`、`think_efforts`；与它们重复的 `reasoning`、`limit` 和其余字段不读、不猜。
- 套餐有效期由用户自己填（2026-11-11 用户要求）。kimi.com 订阅页上的有效期、月度总用量和 Extra Usage，用 API key 都拿不到：2026-11-11 实测，key 能用的 `usages`、`models`、`me` 都没有这些字段；`www.kimi.com/api/...` 不认 API key，只认网页登录态，而网页登录凭据上面已经否决了。日期按账号名称存在 UserDefaults 里，它不是机密，所以不进钥匙串；删除账号时一起删。卡片按本机日历计算剩余天数：还剩 7 天以内显示琥珀色，过期显示红色。App 不发系统通知，所以没有到期提醒弹窗。
