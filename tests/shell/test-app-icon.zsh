#!/bin/zsh -f
# ticket 17：App 图标与菜单栏图标。
#
# 源文件是 Resources/Icons/*.svg，由 scripts/make-icons.sh 生成 Resources/AppIcon.icns（App 图标）
# 和 Resources/MenuBarIcon.pdf（菜单栏"只显示图标"用的模板图），生成结果随仓库提交，
# scripts/build-app.sh 只负责复制。
source "${0:A:h}/lib.zsh"

PLIST=$ROOT/Resources/Info.plist
ICNS=$ROOT/Resources/AppIcon.icns

# .icns 应包含的全部尺寸：16–512pt，各有 1x 与 @2x（即 16–1024 像素）
typeset -A ICONSET_PIXELS
ICONSET_PIXELS=(
  icon_16x16.png 16       icon_16x16@2x.png 32
  icon_32x32.png 32       icon_32x32@2x.png 64
  icon_128x128.png 128    icon_128x128@2x.png 256
  icon_256x256.png 256    icon_256x256@2x.png 512
  icon_512x512.png 512    icon_512x512@2x.png 1024
)

# 解开 .icns，确认每个尺寸都在且像素数正确：assert_full_iconset 文件
assert_full_iconset() {
  local iconset=$T/check-${RANDOM}.iconset name px
  /usr/bin/iconutil -c iconset -o $iconset $1 || fail "iconutil 解不开 $1"
  local -a got want
  got=($iconset/*(N:t))
  want=(${(ok)ICONSET_PIXELS})
  assert_eq "${(oj: :)got}" "${(j: :)want}" "$1 应包含 16–1024 像素的全部尺寸"
  for name px in ${(kv)ICONSET_PIXELS}; do
    assert_eq "$(/usr/bin/sips -g pixelWidth -g pixelHeight $iconset/$name | awk '/pixel/ {print $2}' | paste -sd x -)" \
      "${px}x$px" "$name 的像素尺寸"
  done
}

test_info_plist_names_the_app_icon() {
  assert_eq "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' $PLIST 2>/dev/null)" AppIcon \
    "Info.plist 的 CFBundleIconFile"
  [[ -f $ICNS ]] || fail "缺少 Resources/AppIcon.icns"
}

test_app_icon_contains_every_size() {
  assert_full_iconset $ICNS
}

# 菜单栏模板图是 18pt 见方：1x 为 18 像素，@2x 为 36 像素（是否单色见 tests/swift/AppIconChecks.swift）
assert_menu_bar_icon() {  # 目录
  local name size
  for name size in MenuBarIcon.png 18x18 MenuBarIcon@2x.png 36x36; do
    [[ -f $1/$name ]] || fail "缺少 $1/$name"
    assert_eq "$(/usr/bin/sips -g pixelWidth -g pixelHeight $1/$name | awk '/pixel/ {print $2}' | paste -sd x -)" \
      $size "$name 的像素尺寸"
  done
}

test_menu_bar_icon_is_18pt_with_2x() {
  assert_menu_bar_icon $ROOT/Resources
}

test_make_icons_regenerates_everything_from_svg() {
  # 只用系统自带的 swift 和 iconutil；输出到指定目录，不碰仓库里的产物。
  # 不逐字节比对仓库里的产物：系统升级后 SVG 渲染可能有细微差别
  t_run -- $ROOT/scripts/make-icons.sh $T/icons
  assert_rc 0
  assert_full_iconset $T/icons/AppIcon.icns
  assert_menu_bar_icon $T/icons
}

# 在 $T/repo 里运行 build-app.sh 的组装步骤：编译、合并架构、签名都换成假程序（只产生空文件），
# fetch-sparkle.sh 换成返回一个假的 Sparkle 目录，不联网、不真正编译
run_build_app() {
  mkdir -p -- $T/repo $T/bin $T/sparkle/Sparkle.framework/Versions/B/Updater.app || exit 1
  cp -R -- $ROOT/scripts $ROOT/Resources $ROOT/shell $T/repo/ || exit 1
  : > $T/sparkle/Sparkle.framework/Versions/B/Autoupdate
  print -r -- "#!/bin/zsh -f
print -r -- $T/sparkle" > $T/repo/scripts/fetch-sparkle.sh
  print -r -- '#!/bin/zsh -f
while (( $# )); do [[ $1 == -o || $1 == -output ]] && { : > $2; exit 0 }; shift; done' > $T/bin/swiftc
  cp -- $T/bin/swiftc $T/bin/lipo
  print -r -- '#!/bin/zsh -f' > $T/bin/codesign
  print -r -- '#!/bin/zsh -f
print -r -- /' > $T/bin/xcrun
  chmod +x $T/repo/scripts/fetch-sparkle.sh $T/bin/* || exit 1
  t_run PATH=$T/bin:/usr/bin:/bin:/usr/sbin:/sbin -- /bin/zsh -f $T/repo/scripts/build-app.sh
  assert_rc 0
  APP_RESOURCES="$T/repo/build/CC Pilot.app/Contents/Resources"
  APP_PLIST="$T/repo/build/CC Pilot.app/Contents/Info.plist"
}

test_built_app_contains_the_icon_named_by_info_plist() {
  run_build_app
  local icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' $APP_PLIST 2>/dev/null)
  [[ -n $icon ]] || fail "构建产物的 Info.plist 没有 CFBundleIconFile"
  /usr/bin/cmp -s -- "$APP_RESOURCES/${icon%.icns}.icns" $ICNS ||
    fail "构建产物的 Contents/Resources/${icon%.icns}.icns 应与 Resources/AppIcon.icns 相同"
}

test_built_app_contains_the_menu_bar_icon_but_not_svg_sources() {
  run_build_app
  assert_menu_bar_icon $APP_RESOURCES
  [[ ! -e $APP_RESOURCES/Icons ]] || fail "SVG 源文件不应打包进 App"
}

t_main "$@"
