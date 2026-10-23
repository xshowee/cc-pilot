#!/bin/zsh -f
# 从 Resources/Icons/*.svg 重新生成图标：./scripts/make-icons.sh [输出目录，默认 Resources]
#
# 产物（随仓库提交，scripts/build-app.sh 只复制、不生成）：
#   AppIcon.icns                          App 图标，16–512pt 各含 1x 与 @2x；Info.plist 的 CFBundleIconFile 指向它
#   MenuBarIcon.png、MenuBarIcon@2x.png    菜单栏"只显示图标"用的模板图（18pt，单色）
# 只用 macOS 自带的 swift（NSImage 解析 SVG，见 scripts/render-icons.swift）和 iconutil，不联网。
# 改了 SVG 后运行本脚本，把源文件和产物一起提交。

emulate -R zsh
setopt err_exit pipe_fail

ROOT=${0:A:h:h}
OUT=${1:-$ROOT/Resources}
OUT=${OUT:A}

work=$(mktemp -d "${${TMPDIR:-/tmp}%/}/ccp-icons.XXXXXX")
trap 'rm -rf -- $work' EXIT
mkdir -p -- $OUT $work/ModuleCache

/usr/bin/swift -module-cache-path $work/ModuleCache $ROOT/scripts/render-icons.swift $ROOT/Resources/Icons $work
/usr/bin/iconutil -c icns -o $work/AppIcon.icns $work/AppIcon.iconset
mv -f -- $work/AppIcon.icns $work/MenuBarIcon.png $work/MenuBarIcon@2x.png $OUT/

print -r -- "已生成：$OUT/AppIcon.icns、$OUT/MenuBarIcon.png、$OUT/MenuBarIcon@2x.png"
