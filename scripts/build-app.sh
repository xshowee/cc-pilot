#!/bin/zsh -f
# 构建 CC Pilot.app：./scripts/build-app.sh [--universal] [--sign <身份>] [--hardened-runtime] [--timestamp]
#
# 产物：build/CC Pilot.app。正式发布（Developer ID、公证、DMG、appcast）用 scripts/release.sh，它会调用本脚本。
#   默认只编译本机架构、ad-hoc 签名，只供本机运行；运行：open "build/CC Pilot.app"
#   --universal         编译 arm64 + x86_64 并用 lipo 合并
#   --sign <身份>        签名身份（证书名称或 SHA-1），默认 "-"（ad-hoc）
#   --hardened-runtime  启用 hardened runtime（公证要求）；不启用 App Sandbox
#   App 本体签名时附加 Resources/CCPilot.entitlements：只有 com.apple.security.automation.apple-events，
#   hardened runtime 下发送 Apple 事件（添加/删除档案时让"终端"执行 ccp，ticket 09）需要它。
#   --timestamp         签名带安全时间戳（公证要求，会访问 Apple 的时间戳服务）
#   Sparkle 框架由 scripts/fetch-sparkle.sh 准备（首次下载到 build/deps/），嵌入 Contents/Frameworks/。
#
# 不用 Xcode 工程和 SwiftPM，直接 swiftc 编译、手工组装 .app。
#   Info.plist 是手写的 Resources/Info.plist，版本号和最低系统版本都以它为唯一来源；
#   本地化资源 Resources/*.lproj 原样复制；图标（AppIcon.icns、MenuBarIcon*.png）也只复制不生成：
#   它们由 scripts/make-icons.sh 从 Resources/Icons/*.svg 生成并随仓库提交（ticket 17）；
#   shell/ 原样复制到 Contents/Resources/shell/
#   （安装 ccp 时把它复制到 ~/.cc-pilot/，见 shell/README.md 和 ticket 08）。

emulate -R zsh
setopt err_exit pipe_fail null_glob

ROOT=${0:A:h:h}
cd -- "$ROOT"

APP_NAME="CC Pilot"
EXECUTABLE=CCPilot
BUILD=$ROOT/build
APP="$BUILD/$APP_NAME.app"
PLIST=Resources/Info.plist
ENTITLEMENTS=Resources/CCPilot.entitlements
ICONS=(Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png)

archs=($(uname -m))
identity=-
typeset -a sign_opts
sign_opts=(--timestamp=none)
while (( $# )); do
  case $1 in
    --universal) archs=(arm64 x86_64) ;;
    --sign) identity=${2-}; shift ;;
    --hardened-runtime) sign_opts+=(--options runtime) ;;
    --timestamp) sign_opts=(${sign_opts:#--timestamp=none} --timestamp) ;;
    *) print -u2 -r -- "用法：$0 [--universal] [--sign <身份>] [--hardened-runtime] [--timestamp]"; exit 2 ;;
  esac
  shift
done
[[ -n $identity ]] || { print -u2 -r -- "--sign 需要一个签名身份"; exit 2 }

MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' $PLIST)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $PLIST)
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' $PLIST) == $EXECUTABLE ]] || {
  print -u2 -r -- "Info.plist 的 CFBundleExecutable 应为 $EXECUTABLE"; exit 1
}

print -r -- "==> 检查资源文件"
/usr/bin/plutil -lint -s $PLIST $ENTITLEMENTS Resources/*.lproj/*.strings

SPARKLE=$(./scripts/fetch-sparkle.sh)

print -r -- "==> 编译 $EXECUTABLE $VERSION（${(j:, :)archs}，macOS $MIN_MACOS+）"
SDK=$(xcrun --show-sdk-path)
mkdir -p -- $BUILD/obj
typeset -a slices
for arch in $archs; do
  slice=$BUILD/obj/$EXECUTABLE-$arch
  swiftc -O -swift-version 5 -parse-as-library \
    -sdk $SDK -target $arch-apple-macos$MIN_MACOS \
    -module-name $EXECUTABLE -module-cache-path $BUILD/obj/ModuleCache \
    -F $SPARKLE -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Core/*.swift Sources/App/*.swift -o $slice
  slices+=($slice)
done

print -r -- "==> 组装 $APP"
rm -rf -- "$APP"
mkdir -p -- "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create $slices -output "$APP/Contents/MacOS/$EXECUTABLE"
cp -- $PLIST "$APP/Contents/Info.plist"
cp -R -- Resources/*.lproj "$APP/Contents/Resources/"
cp -- $ICONS "$APP/Contents/Resources/"
cp -R -- shell "$APP/Contents/Resources/shell"
# App 不启用沙盒，用不到 Sparkle 的 XPC 服务，删掉以减小体积
sparkle_fw="$APP/Contents/Frameworks/Sparkle.framework"
ditto $SPARKLE/Sparkle.framework "$sparkle_fw"
rm -rf -- "$sparkle_fw/XPCServices" "$sparkle_fw/Versions/B/XPCServices"

print -r -- "==> 签名（${${identity:#-}:-ad-hoc}）"
# hardened runtime 的库校验要求框架与 App 同一团队签名，所以由内向外重签 Sparkle
for code in "$sparkle_fw/Versions/B/Autoupdate" "$sparkle_fw/Versions/B/Updater.app" "$sparkle_fw"; do
  codesign --force $sign_opts --sign $identity "$code"
done
codesign --force $sign_opts --entitlements $ENTITLEMENTS --sign $identity "$APP"
codesign --verify --deep --strict "$APP"

print -r -- "完成：$APP"
