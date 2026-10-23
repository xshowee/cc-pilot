# 档案按配置目录隔离，不覆盖凭据

每个档案是一个独立的 `CLAUDE_CONFIG_DIR`。Claude Code 会据此使用独立的钥匙串项（service 名带上目录 hash 后缀）和独立的 `.claude.json`。切换只改写"当前档案"这一条记录，由 shell 包装函数在新会话启动时读取。cc-pilot 对凭据只读：从不写入钥匙串，也从不刷新 token。

## Considered Options

- **覆盖全局凭据**（codex-pilot 的做法：退出客户端，把快照覆盖到 `auth.json`，再重新打开）。没有采用，原因有三：Claude Code 是 CLI，可能同时开着多个会话，没有"先退出再切换"的时机；已在运行的会话一旦刷新 token，就会把刚换上的凭据写回去覆盖掉；refresh token 会轮换，多份快照很容易失效，而 Claude Code 刷新时遇到 `invalid_grant` 会直接清空本地 token。

## Consequences

- 已在运行的会话不会跟着切换，只有新会话使用新档案；不同终端可以同时使用不同账号。
- 不经过 shell 包装函数的入口（IDE 插件、Claude Desktop、其他 shell）始终使用默认档案。
- 档案不能改名：目录路径决定了钥匙串项的名字。
- 依赖 Claude Code 内部计算钥匙串 service 名的方式（以 2.1.309 为准），Claude Code 更新后需要验证。
- 读取凭据和 Claude Code 自己的读法一致，都是调用 `/usr/bin/security find-generic-password`，因为钥匙串项是由 `security` 创建的，用它读取不会弹出授权窗。不用 Security framework：它按 App 自身的签名授权，每次签名变化都会重新弹窗。如果读取时出现弹窗或返回空值，就当作 Claude Code 改变了存储方式，提示"版本不兼容"。
- 由于要启动子进程、读取别的程序创建的钥匙串项，App 不能启用 App Sandbox，也就无法上架 Mac App Store。
