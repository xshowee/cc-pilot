# 发布 CC Pilot

构建、签名、公证、打包 DMG 和生成 appcast 由一条命令完成：

```zsh
./scripts/release.sh
```

它依次执行：发布前检查 → universal 构建（arm64 + x86_64）→ Developer ID 签名（hardened runtime，带时间戳，
不启用 App Sandbox，只有发送 Apple 事件的 entitlement）→ 公证并 staple App → 打包 `build/CCPilot-<版本>.dmg` →
签名、公证并 staple DMG → Gatekeeper 校验 → 用 Sparkle 的 `generate_appcast --account cc-pilot`
把新版本加进仓库根目录的 `appcast.xml`（EdDSA 签名，更新说明嵌入其中）。

上传 DMG、推送 appcast 不在脚本里，由你手动完成（见下面的"每次发布"）。

相关文件：

| 文件 | 作用 |
| --- | --- |
| `scripts/release.sh` | 正式发布（本文的主角） |
| `scripts/build-app.sh` | 编译并组装 `build/CC Pilot.app`；release.sh 调用它。单独运行时是本机架构、ad-hoc 签名的开发构建 |
| `scripts/fetch-sparkle.sh` | 首次运行时下载 Sparkle 2.10.0 到 `build/deps/` 并校验 SHA-256，之后不联网 |
| `Resources/Info.plist` | 版本号、Sparkle 配置（更新地址、公钥、每天检查一次、默认开启、不上报系统信息）的唯一来源 |
| `Sources/App/Updater.swift` | 面板设置菜单里的"检查更新…"与"自动检查更新" |
| `Sources/Core/LaunchAtLogin.swift`、`Sources/App/LaunchAtLoginModel.swift` | "登录时启动"（`SMAppService.mainApp`，默认关闭） |

环境变量（都可省略）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CCP_TEAM_ID` | 无 | 签名所属团队 |
| `CCP_RELEASE_IDENTITY` | 该团队的 Developer ID Application 证书 | 签名身份（名称或 SHA-1）；`-` 为 ad-hoc，只能和 `CCP_SKIP_NOTARIZE=1` 一起用 |
| `CCP_NOTARY_PROFILE` | `cc-pilot-notary` | notarytool 的钥匙串凭据名 |
| `CCP_RELEASE_NOTES` | 无 | 本版更新说明（Markdown 文件），显示在 Sparkle 的更新窗口里 |
| `CCP_SKIP_NOTARIZE=1` | 关 | 只在本机验证打包流程：跳过公证、Sparkle 私钥检查和 appcast 生成，产物不能分发 |
| `CCP_SPARKLE_DIR` | 无 | 使用已解压好的同版本 Sparkle，不下载 |

> **待确认：仓库地址。** 脚本和 `SUFeedURL` 假定仓库是 `https://github.com/xshowee/cc-pilot`，
> appcast 地址是 `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml`。
> 如果不是，改 `Resources/Info.plist` 的 `SUFeedURL` 和 `scripts/release.sh` 的 `REPO_URL`。
> 这个仓库必须是公开的，否则已安装的 App 读不到 appcast。

## 一次性准备（按顺序执行）

以下步骤会写入钥匙串或访问 Apple 的服务，需要你亲自执行。在仓库根目录下运行。

### 1. 确认 Developer ID 证书

```zsh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

应能看到形如 `Developer ID Application: <名字> (<Team ID>)` 的证书。

### 2. 保存公证凭据

二选一：

```zsh
# a) 为 cc-pilot 单独保存一份（脚本默认用这个名字）
xcrun notarytool store-credentials cc-pilot-notary --apple-id <Apple ID> --team-id <Team ID>
#    会提示输入 App 专用密码（appleid.apple.com 生成）

# b) 或者复用同一开发者账号已保存的凭据：之后每次发布前
export CCP_NOTARY_PROFILE=<凭据名>
```

验证：`xcrun notarytool history --keychain-profile cc-pilot-notary`能列出记录、不报错。

### 3. 生成 cc-pilot 专用的 Sparkle 密钥

cc-pilot 的 EdDSA 密钥单独新建，存放在钥匙串的 `cc-pilot` 账户下，不用默认账户。

```zsh
SPARKLE=$(./scripts/fetch-sparkle.sh)

# 生成密钥：私钥存进登录钥匙串（会弹窗请求保存），终端打印公钥
"$SPARKLE/bin/generate_keys" --account cc-pilot

# 把打印出的公钥（base64，以 = 结尾）填进 Info.plist，替换占位值 AAAA…A=
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey <公钥>" Resources/Info.plist

# 确认钥匙串里的公钥与 Info.plist 一致（两行应相同）
"$SPARKLE/bin/generate_keys" -p --account cc-pilot
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist
```

然后提交 `Resources/Info.plist`（只改了 `SUPublicEDKey` 一行）。Info.plist 里不写注释，因为 PlistBuddy 写回时会删掉它们；
各个键的含义见本文末尾的"Info.plist 中与发布有关的键"。

**备份私钥**（丢了就无法再给已安装的用户推送更新）：

```zsh
"$SPARKLE/bin/generate_keys" --account cc-pilot -x ~/Desktop/cc-pilot-sparkle-private-key
# 把文件存进密码管理器，然后删掉：
rm ~/Desktop/cc-pilot-sparkle-private-key
```

换电脑时导入：`"$SPARKLE/bin/generate_keys" --account cc-pilot -f <私钥文件>`。私钥文件绝不放进仓库。

占位值没有替换时，`./scripts/release.sh` 会拒绝发布；钥匙串里 `cc-pilot` 账户的公钥与 Info.plist 不一致时也会拒绝。
占位值期间构建出的 App（例如本地开发构建）不会启动 Sparkle，"检查更新…"是灰的，也不会访问 appcast。

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
```

### 2. 构建、签名、公证、打包、生成 appcast

```zsh
CCP_RELEASE_NOTES=/path/to/notes-0.2.0.md ./scripts/release.sh    # 没有更新说明就省掉变量
```

公证每次通常要几分钟。生成 appcast 时 `generate_appcast` 要读钥匙串里 `cc-pilot` 账户的私钥，
第一次可能弹窗询问，选"始终允许"。成功后得到 `build/CCPilot-0.2.0.dmg`，仓库根目录的 `appcast.xml` 已更新（尚未提交）。

### 3. 先上传 DMG

```zsh
gh release create v0.2.0 build/CCPilot-0.2.0.dmg --title "CC Pilot 0.2.0" --notes-file /path/to/notes-0.2.0.md
```

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

在一台没装过 CC Pilot 的机器（或先 `defaults delete com.ccpilot.app`）上首次打开，点面板左下角的齿轮：

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
| 启动、打开面板、切换档案、空闲 | 无 |
| 点"刷新全部"或单个账号的刷新 | 只有 `api.anthropic.com` |
| 每天一次的后台检查、点"检查更新…" | 只有 `raw.githubusercontent.com`（appcast），请求不带查询参数（不上报系统信息） |
| 确认安装更新、下载过程中 | `github.com` 及其下载跳转到的 `*.githubusercontent.com`（DMG 附件） |

更新说明嵌入在 appcast 里，Sparkle 不会再去请求别的页面；"查看完整更新说明"只会在你点击时用浏览器打开。

## 排查

- **公证未通过**：脚本会打印 `notarytool log`。常见原因是某个可执行文件没有 hardened runtime 或时间戳；
  `scripts/build-app.sh` 由内向外重签 Sparkle 的 `Autoupdate`、`Updater.app`、框架本身和 App。
- **"钥匙串里账户 cc-pilot 的 Sparkle 公钥与 SUPublicEDKey 不匹配"**：Info.plist 里填的不是这把密钥的公钥，
  或者钥匙串里导入的是别的私钥。已发布的版本只认它 Info.plist 里的公钥，换钥匙会让老用户收不到更新。
- **用户报告"更新失败"**：先确认 Release 附件名是 `CCPilot-<版本>.dmg`、tag 是 `v<版本>`，且 appcast 是在附件上传之后才推送的。

## Info.plist 中与发布有关的键

| 键 | 值 | 含义 |
| --- | --- | --- |
| `CFBundleShortVersionString` | `0.1.0` | 显示给用户的版本号；也决定 DMG 名和 Release tag |
| `CFBundleVersion` | `1` | 整数构建号，Sparkle 按它比较新旧，每次发布必须递增 |
| `SUFeedURL` | `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml` | appcast 地址，App 访问的两个网络地址之一 |
| `SUPublicEDKey` | 占位值 `AAAA…A=`（32 个零字节） | cc-pilot 的 Sparkle EdDSA 公钥；占位值时 release.sh 拒绝发布，App 不启动 Sparkle |
| `SUEnableAutomaticChecks` | `true` | 自动检查更新默认开启，并且不弹窗询问 |
| `SUScheduledCheckInterval` | `86400` | 每天检查一次 |
| `SUEnableSystemProfiling` | `false` | 请求 appcast 时不附带系统信息 |
| `SURequireSignedFeed` | `true` | appcast 整体必须带 EdDSA 签名 |
| `SUVerifyUpdateBeforeExtraction` | `true` | 解压更新包之前先校验签名 |
