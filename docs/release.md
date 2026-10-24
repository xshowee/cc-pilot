# 发布 CC Pilot

构建、签名、公证、打包 DMG 和生成 appcast 由一条命令完成：

```zsh
./scripts/release.sh
```

它依次执行：发布前检查 → universal 构建（arm64 + x86_64）→ Developer ID 签名（hardened runtime，带时间戳，
不启用 App Sandbox，只有发送 Apple 事件的 entitlement）→ 公证并 staple App → 打包 `build/CCPilot-<版本>.dmg` →
签名、公证并 staple DMG → Gatekeeper 校验 → 用 Sparkle 的 `generate_appcast --account cc-pilot`
把新版本加进仓库根目录的 `appcast.xml`（EdDSA 签名，更新说明嵌入其中）。

上传 DMG、推送 appcast 不在脚本里，手动完成（见下面的"每次发布"）。

相关文件：

| 文件 | 作用 |
| --- | --- |
| `scripts/release.sh` | 正式发布 |
| `scripts/build-app.sh` | 编译并组装 `build/CC Pilot.app`；release.sh 调用它。单独运行时是本机架构、ad-hoc 签名的开发构建 |
| `scripts/fetch-sparkle.sh` | 首次运行时下载 Sparkle 2.10.0 到 `build/deps/` 并校验 SHA-256，之后不联网 |
| `Resources/Info.plist` | 版本号、Sparkle 配置（更新地址、公钥、每天检查一次、默认开启、不上报系统信息）的唯一来源 |
| `Resources/Icons/*.svg`、`scripts/make-icons.sh` | 图标源文件与重新生成命令；产物 `Resources/AppIcon.icns`、`Resources/MenuBarIcon*.png` 随仓库提交（见"图标"） |
| `Sources/App/Updater.swift` | 面板设置菜单里的"检查更新…"与"自动检查更新" |
| `Sources/Core/LaunchAtLogin.swift`、`Sources/App/LaunchAtLoginModel.swift` | "登录时启动"（`SMAppService.mainApp`，默认关闭） |

环境变量（都可省略）。经常要设置的可以写进仓库根目录的 `.env`（被 git 忽略，从 `.env.example` 复制），
release.sh 启动时读取其中 `NAME=值` 形式的行；命令行里设置的同名变量优先。Team ID 这类本机信息只写在 `.env` 里，
不要写进仓库。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CCP_TEAM_ID` | 钥匙串里 Developer ID Application 证书所属的团队 | 签名所属团队；钥匙串里有多个团队的证书时必须指定 |
| `CCP_RELEASE_IDENTITY` | 该团队的 Developer ID Application 证书 | 签名身份（名称或 SHA-1）；`-` 为 ad-hoc，只能和 `CCP_SKIP_NOTARIZE=1` 一起用 |
| `CCP_NOTARY_PROFILE` | `cc-pilot-notary` | notarytool 的钥匙串凭据名 |
| `CCP_RELEASE_NOTES` | 无 | 本版更新说明（Markdown 文件），显示在 Sparkle 的更新窗口里 |
| `CCP_SKIP_NOTARIZE=1` | 关 | 只在本机验证打包流程：跳过公证、Sparkle 私钥检查和 appcast 生成，产物不能分发 |
| `CCP_SPARKLE_DIR` | 无 | 使用已解压好的同版本 Sparkle，不下载 |

仓库地址写在 `Resources/Info.plist` 的 `SUFeedURL`（appcast 地址
`https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml`）和 `scripts/release.sh` 的 `REPO_URL` 里。
仓库必须是公开的，否则已安装的 App 读不到 appcast。

## 一次性准备（按顺序执行）

每台用来发布的机器执行一次。以下步骤会写入钥匙串或访问 Apple 的服务，在仓库根目录下运行。

### 1. 确认 Developer ID 证书

```zsh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

应能看到形如 `Developer ID Application: <名字> (<Team ID>)` 的证书。release.sh 自动使用它；
钥匙串里有多个团队的证书时，用 `CCP_TEAM_ID` 指定。

### 2. 保存公证凭据

```zsh
xcrun notarytool store-credentials cc-pilot-notary --apple-id <Apple ID> --team-id <Team ID>
#    会提示输入 App 专用密码（appleid.apple.com 生成）
```

已经用别的名字保存过同一个开发者账号的凭据，也可以不再保存，发布前设置 `CCP_NOTARY_PROFILE=<凭据名>`。

验证：`xcrun notarytool history --keychain-profile cc-pilot-notary` 能列出记录、不报错。

### 3. 导入 Sparkle 私钥

cc-pilot 的 EdDSA 密钥存放在钥匙串的 `cc-pilot` 账户下（不用默认账户），公钥写在 `Resources/Info.plist` 的
`SUPublicEDKey` 里。已安装的 App 只接受这把密钥签名的更新，所以换电脑时导入备份的私钥，**不要重新生成**：

```zsh
SPARKLE=$(./scripts/fetch-sparkle.sh)
"$SPARKLE/bin/generate_keys" --account cc-pilot -f <私钥文件>

# 确认钥匙串里的公钥与 Info.plist 一致（两行应相同）
"$SPARKLE/bin/generate_keys" -p --account cc-pilot
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist
```

**备份私钥**（丢了就无法再给已安装的用户推送更新）：

```zsh
"$SPARKLE/bin/generate_keys" --account cc-pilot -x ~/Desktop/cc-pilot-sparkle-private-key
# 把文件存进密码管理器，然后删掉：
rm ~/Desktop/cc-pilot-sparkle-private-key
```

私钥文件绝不放进仓库。

fork 后自行发布时才需要新建密钥：`"$SPARKLE/bin/generate_keys" --account cc-pilot` 生成私钥并打印公钥，
再用 `/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey <公钥>" Resources/Info.plist` 填进去。
Info.plist 里不写注释，因为 PlistBuddy 写回时会删掉它们；各个键的含义见本文末尾的"Info.plist 中与发布有关的键"。

`SUPublicEDKey` 是占位值 `AAAA…A=` 时，`./scripts/release.sh` 会拒绝发布，构建出的 App 也不启动 Sparkle
（"检查更新…"是灰的，不访问 appcast）；钥匙串里 `cc-pilot` 账户的公钥与 Info.plist 不一致时 release.sh 同样拒绝。
Info.plist 里是真实公钥时，**包括本地开发构建在内**，App 都会启动 Sparkle 并按计划访问 appcast 地址。

### 4.（建议）先在本机试一遍签名

```zsh
CCP_SKIP_NOTARIZE=1 ./scripts/release.sh
```

用 Developer ID 签名、打包 DMG，但不公证、不生成 appcast。第一次用这张证书给 cc-pilot 签名时，
钥匙串可能弹窗询问 `codesign` 能否使用私钥，选"始终允许"。最后的 Gatekeeper 评估显示 `rejected` 属预期（还没公证）。

## 每次发布（按顺序执行）

### 1. 递增版本号

两个都要改。Sparkle 按 `CFBundleVersion`（整数）比较新旧，**每次发布必须比上一次大**。

```zsh
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.0" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2" Resources/Info.plist
git commit -am "chore(release): 版本 0.2.0（2）" -m "递增版本号与构建号，准备发布 0.2.0。"
git push
```

马上推送，因为第 3 步要把 tag 打在这个提交上，GitHub 只能给远端已有的提交打 tag。
此时 appcast 还没变，推送不会让已安装的 App 发现新版本。

### 2. 构建、签名、公证、打包、生成 appcast

```zsh
CCP_RELEASE_NOTES=/path/to/notes-0.2.0.md ./scripts/release.sh    # 没有更新说明就省掉变量
```

公证每次通常要几分钟。生成 appcast 时 `generate_appcast` 要读钥匙串里 `cc-pilot` 账户的私钥，
第一次可能弹窗询问，选"始终允许"。成功后得到 `build/CCPilot-0.2.0.dmg`，仓库根目录的 `appcast.xml` 已更新（尚未提交）。

### 3. 先上传 DMG

```zsh
gh release create v0.2.0 build/CCPilot-0.2.0.dmg --title "CC Pilot 0.2.0" --notes-file /path/to/notes-0.2.0.md \
  --target "$(git rev-parse HEAD)"
```

`--target` 把 tag 打在第 1 步的版本号提交上（此时 HEAD 就是它，appcast 还没提交）。
不加的话，tag 打在远端 main 当时的最新提交上，不一定是构建 DMG 用的那个提交。

tag 必须是 `v<版本>`，附件名必须保持 `CCPilot-<版本>.dmg`：appcast 里的下载地址是
`https://github.com/xshowee/cc-pilot/releases/download/v<版本>/CCPilot-<版本>.dmg`。

### 4. 最后提交并推送 appcast

```zsh
git add appcast.xml
git commit -m "chore(release): appcast 加入 0.2.0" -m "发布 0.2.0：DMG 已上传到 GitHub Release v0.2.0。"
git push
```

顺序不能反：appcast 先推上去而 DMG 还没上传，已安装的 App 会发现新版本却下载失败。
`appcast.xml` 末尾带签名，不要手改；需要改就重新运行 `./scripts/release.sh`。

## 人工验证（发布后）

### Gatekeeper 与架构

1. 在浏览器里从 GitHub Release 下载 DMG（这样带有隔离属性，和用户一样），打开，把 CC Pilot 拖进"应用程序"。
2. 打开 `/Applications/CC Pilot.app`：不应出现"无法验证开发者"之类的提示。
3. 终端确认：

   ```zsh
   spctl --assess --type execute -vv "/Applications/CC Pilot.app"   # accepted, source=Notarized Developer ID
   xcrun stapler validate "/Applications/CC Pilot.app"              # The validate action worked!
   lipo -archs "/Applications/CC Pilot.app/Contents/MacOS/CCPilot"  # x86_64 arm64
   codesign -d --entitlements - "/Applications/CC Pilot.app"        # 只有 com.apple.security.automation.apple-events
   ```

4. 签名后的版本里，读取凭据仍然正常：对一个已登录的档案点刷新，能显示额度，且不弹出钥匙串授权窗口
   （凭据由子进程 `/usr/bin/security` 读取，与 App 的签名无关）。

### 默认设置

在一台没装过 CC Pilot 的机器（或先 `defaults delete com.ccpilot.app`）上首次打开，点面板右下角的齿轮：

- "自动检查更新"已勾选，且没有弹出"是否自动检查更新"的询问；
- "登录时启动"未勾选。勾选后"系统设置 › 通用 › 登录项"里出现 CC Pilot，注销再登录 App 会自动启动；
  取消勾选后从登录项中消失。

### 自动更新

1. 先安装旧版本（例如 0.1.0），再按"每次发布"发布一个新版本（例如 0.2.0）。
2. 手动：齿轮菜单 → "检查更新…"，应显示 0.2.0 和更新说明 → 安装 → App 自动退出并重启，
   `defaults read "/Applications/CC Pilot.app/Contents/Info" CFBundleShortVersionString` 为 0.2.0。
3. 定时（每天一次）：装回旧版本，执行
   `defaults write com.ccpilot.app SULastCheckTime -date "2020-01-01 00:00:00 +0000"` 后重新打开 App。
   Sparkle 会立即做一次后台检查；菜单栏 App 不会抢焦点弹窗，而是把齿轮图标换成下载箭头，
   菜单项变成"有可用更新…"。

### 网络访问（抓包）

用 Little Snitch、LuLu 或 `nettop -m tcp -p "$(pgrep -x CCPilot)"` 观察 CCPilot 进程。预期：

| 时机 | 应出现的连接 |
| --- | --- |
| 打开面板、切换档案 | 无 |
| 点"刷新全部"或单个账号的刷新 | 只有 `api.anthropic.com` |
| 开启"自动检查更新"（默认）时的后台检查：每天一次，距上次检查已满一天时在启动后不久检查；以及点"检查更新…" | 只有 `raw.githubusercontent.com`（appcast），请求不带查询参数（不上报系统信息） |
| 其余时候：启动、空闲但距上次检查未满一天，或已关掉"自动检查更新" | 无 |
| 确认安装更新、下载过程中 | `github.com` 及其下载跳转到的 `*.githubusercontent.com`（DMG 附件） |

更新说明嵌入在 appcast 里，Sparkle 不会再去请求别的页面；"查看完整更新说明"只会在你点击时用浏览器打开。

## 图标

源文件在 `Resources/Icons/`：

| 源文件 | 产物 | 用途 |
| --- | --- | --- |
| `AppIcon.svg` | `Resources/AppIcon.icns` 中 64 像素及以上的尺寸 | App 图标（Finder、"应用程序"、DMG、"关于"、登录项） |
| `AppIcon-small.svg` | `Resources/AppIcon.icns` 中 16、32 像素 | 同上的简化版：去掉阴影和窗口圆点、提示符加粗 |
| `MenuBarIcon.svg` | `Resources/MenuBarIcon.png`（18 像素）、`MenuBarIcon@2x.png`（36 像素） | 菜单栏"只显示图标"的模板图（18pt，单色，系统按明暗着色） |

改了 SVG 之后重新生成，并把源文件和产物一起提交：

```zsh
./scripts/make-icons.sh
git add Resources/Icons Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png
```

脚本只用系统自带的 `swift`（`NSImage` 解析 SVG，见 `scripts/render-icons.swift`）和 `iconutil`，不联网。
产物提交进仓库而不是构建时生成，因为 `build-app.sh` 只编译和复制、没有生成步骤，
这样每次构建和发布用的都是同一份已审过的图标，不受构建机器上 SVG 渲染差异的影响。
`Info.plist` 的 `CFBundleIconFile` 是 `AppIcon`。`tests/shell/test-app-icon.zsh` 检查尺寸齐全、构建产物里有图标，
`tests/swift/AppIconChecks.swift` 检查菜单栏图只有黑色与透明度。

Finder 和 Dock 会缓存图标。换了图标后如果看到的还是旧的，执行 `touch "/Applications/CC Pilot.app"`，再重新打开 Finder 窗口。

## 排查

- **公证未通过**：脚本会打印 `notarytool log`。常见原因是某个可执行文件没有 hardened runtime 或时间戳；
  `scripts/build-app.sh` 由内向外重签 Sparkle 的 `Autoupdate`、`Updater.app`、框架本身和 App。
- **"钥匙串里账户 cc-pilot 的 Sparkle 公钥与 SUPublicEDKey 不匹配"**：Info.plist 里填的不是这把密钥的公钥，
  或者钥匙串里导入的是别的私钥。已发布的版本只认它 Info.plist 里的公钥，换钥匙会让老用户收不到更新。
- **用户报告"更新失败"**：先确认 Release 附件名是 `CCPilot-<版本>.dmg`、tag 是 `v<版本>`，且 appcast 是在附件上传之后才推送的。

## Info.plist 中与发布有关的键

| 键 | 值 | 含义 |
| --- | --- | --- |
| `CFBundleShortVersionString` | `0.2.0` | 显示给用户的版本号；也决定 DMG 名和 Release tag |
| `CFBundleVersion` | `2` | 整数构建号，Sparkle 按它比较新旧，每次发布必须递增 |
| `SUFeedURL` | `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml` | appcast 地址，App 访问的两个网络地址之一 |
| `SUPublicEDKey` | `C1jTICc74ojwE8JFp+JRM88pOXjaZKC7zUcnZLpdzqI=` | cc-pilot 的 Sparkle EdDSA 公钥（钥匙串 `cc-pilot` 账户里私钥对应的公钥）；若换回占位值 `AAAA…A=`，release.sh 拒绝发布，App 不启动 Sparkle |
| `SUEnableAutomaticChecks` | `true` | 自动检查更新默认开启，并且不弹窗询问 |
| `SUScheduledCheckInterval` | `86400` | 每天检查一次 |
| `SUEnableSystemProfiling` | `false` | 请求 appcast 时不附带系统信息 |
| `SURequireSignedFeed` | `true` | appcast 整体必须带 EdDSA 签名 |
| `SUVerifyUpdateBeforeExtraction` | `true` | 解压更新包之前先校验签名 |
