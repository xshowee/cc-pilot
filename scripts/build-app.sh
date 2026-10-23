#!/bin/zsh -f
# 本地构建 CC Pilot.app：./scripts/build-app.sh [--universal]
#
# 产物：build/CC Pilot.app（ad-hoc 签名，只供本机运行；正式签名、公证、Sparkle、DMG 由 ticket 14 加上）。
#   默认只编译本机架构；--universal 编译 arm64 + x86_64 并用 lipo 合并。
#   运行：open "build/CC Pilot.app"
#
# 不用 Xcode 工程和 SwiftPM，直接 swiftc 编译、手工组装 .app。
#   Info.plist 是手写的 Resources/Info.plist，版本号和最低系统版本都以它为唯一来源；
#   本地化资源 Resources/*.lproj 原样复制；shell/ 原样复制到 Contents/Resources/shell/
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

archs=($(uname -m))
for arg in "$@"; do
  case $arg in
    --universal) archs=(arm64 x86_64) ;;
    *) print -u2 -r -- "用法：$0 [--universal]"; exit 2 ;;
  esac
done

MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' $PLIST)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $PLIST)
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' $PLIST) == $EXECUTABLE ]] || {
  print -u2 -r -- "Info.plist 的 CFBundleExecutable 应为 $EXECUTABLE"; exit 1
}

print -r -- "==> 检查资源文件"
/usr/bin/plutil -lint -s $PLIST Resources/*.lproj/*.strings

print -r -- "==> 编译 $EXECUTABLE $VERSION（${(j:, :)archs}，macOS $MIN_MACOS+）"
SDK=$(xcrun --show-sdk-path)
mkdir -p -- $BUILD/obj
typeset -a slices
for arch in $archs; do
  slice=$BUILD/obj/$EXECUTABLE-$arch
  swiftc -O -swift-version 5 -parse-as-library \
    -sdk $SDK -target $arch-apple-macos$MIN_MACOS \
    -module-name $EXECUTABLE -module-cache-path $BUILD/obj/ModuleCache \
    Sources/Core/*.swift Sources/App/*.swift -o $slice
  slices+=($slice)
done

print -r -- "==> 组装 $APP"
rm -rf -- "$APP"
mkdir -p -- "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create $slices -output "$APP/Contents/MacOS/$EXECUTABLE"
cp -- $PLIST "$APP/Contents/Info.plist"
cp -R -- Resources/*.lproj "$APP/Contents/Resources/"
cp -R -- shell "$APP/Contents/Resources/shell"

print -r -- "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

print -r -- "完成：$APP"
