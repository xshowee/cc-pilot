# Kimi Code 只显示额度，API key 由 cc-pilot 保存在钥匙串

cc-pilot 显示 Kimi Code 的额度，但不把它做成第三个工具：没有档案、不能切换、没有实时额度。额度用用户在 Kimi Code 控制台创建的 API key 请求 `https://api.kimi.com/coding/v1/usages` 获取；一个 Kimi Code 账号是用户起的名称加一个 key，可以有多个；添加入口与另外两个工具相同（面板的"添加账号…"里选 Kimi Code），只是不打开终端登录，而是直接填 key，保存在登录钥匙串里 cc-pilot 自己的项中。这是 cc-pilot 唯一自己保存的凭据——Claude Code 和 ChatGPT 的凭据仍然只读、从不写入。

## Considered Options

- **读 Kimi Code CLI 的登录凭据**（`~/.kimi-code/credentials/`）：与另外两个工具的做法一致，不用保存任何东西。没有采用：凭据约 15 分钟过期，而 cc-pilot 不续期；请求还要带上与官方客户端相同的设备标识头，违背"如实标明 cc-pilot、不冒充官方客户端"；没装 CLI 的用户完全用不了。
- **读浏览器里 kimi.com 的 Cookie**：没有采用：要完全磁盘访问权限，且网络层按约定不存、不带 Cookie。
- **做成带档案和切换的第三个工具**：没有采用：用户只要额度；Kimi Code 的所有设备和 API key 共用同一份额度，没有可切换的对象。

## Consequences

- 钥匙串不再是纯只读：每个 Kimi Code 账号多一项 `cc-pilot Kimi Code API key`（account 是账号名称），用 Security 框架读写（不经 `/usr/bin/security`，免得 key 出现在命令行参数里）。检查程序通过 `CoreEnvironment.kimiKeys` 换成内存里的假实现。
- 接口是实验性的、没有官方文档。只读实测过的 `usages.limit_5h` / `limit_7d`；其余字段含义因套餐而异，不读、不猜，格式变了就提示"接口可能已变化"。
- 响应里没有邮箱和套餐，无法识别账号：额度按用户起的名称记，两个 key 属于同一个 Kimi 账户时也各显示各的；删除账号时必须丢掉旧数字（同名可能再加另一个 key）。
- 卡片上可以复制 API key（2026-11-10 用户要求）：key 会离开钥匙串，所以写剪贴板时只留本机（不经通用剪贴板同步）、标记为机密和临时（nspasteboard.org 的约定，剪贴板管理工具不记历史），一分钟后或 App 退出时，剪贴板还是这次写入的内容就清空，被用户别的复制覆盖了就不动（`SecretClipboard`）。
- 删除不经 `ccp`：在面板里确认后直接从钥匙串移除 key。没有"更换 key"，删除后重新添加。
- Kimi Code 不在 `Tool` 里（添加表单为此另有一个只在界面用的选择项），菜单栏、统计面板、Token 用量都没有它。
