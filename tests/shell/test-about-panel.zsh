#!/bin/zsh -f
# ticket 27：齿轮菜单里的"关于 CC Pilot"。
#
# 关于面板本身是系统标准面板（NSApp.orderFrontStandardAboutPanel），外观要真机确认；
# 能在本地验证的是它读取的资料：Info.plist 的版权行与 LICENSE 一致，
# 菜单项和 credits（项目主页、MIT 许可证）的文字有中文翻译。
source "${0:A:h}/lib.zsh"

PLIST=$ROOT/Resources/Info.plist
ZH=$ROOT/Resources/zh-Hans.lproj
ABOUT_SRC=$ROOT/Sources/App/AboutPanel.swift
plist() { /usr/libexec/PlistBuddy -c "Print :$1" $PLIST 2>/dev/null }

# 取出 .strings 文件里某个键的翻译（本仓库的 .strings 每行一条 "键" = "值";）：zh_string 文件 键
# 不用 plutil -extract：它把键里的 . 当成路径分隔符
zh_string() {
  local line prefix="\"$2\" = \""
  for line in "${(@f)$(< $1)}"; do
    if [[ $line == "$prefix"*'";' ]]; then
      line=${line#"$prefix"}
      print -r -- ${line%'";'}
      return
    fi
  done
}

test_copyright_line_matches_license() {
  local copyright=$(plist NSHumanReadableCopyright)
  assert_eq "$copyright" "Copyright (c) 2026 xshowee" "Info.plist 的 NSHumanReadableCopyright"
  local -a license_lines
  license_lines=(${(M)${(f)"$(< $ROOT/LICENSE)"}:#Copyright *})
  assert_eq "${(j:|:)license_lines}" "$copyright" "版权行应与 LICENSE 一致"
  # 版权行不翻译：中文 InfoPlist.strings 不应另写一份
  [[ -z $(zh_string $ZH/InfoPlist.strings NSHumanReadableCopyright) ]] ||
    fail "zh-Hans InfoPlist.strings 不应覆盖 NSHumanReadableCopyright"
}

test_about_menu_item_is_translated() {
  assert_eq "$(zh_string $ZH/Localizable.strings 'About CC Pilot')" "关于 CC Pilot" "菜单项的中文"
  [[ $(< $ROOT/Sources/App/SettingsMenu.swift) == *'"About CC Pilot"'* ]] ||
    fail "SettingsMenu.swift 应有 \"About CC Pilot\" 菜单项"
}

test_credits_show_homepage_and_mit_license_in_both_languages() {
  [[ -f $ABOUT_SRC ]] || fail "缺少 $ABOUT_SRC"
  local src=$(< $ABOUT_SRC)
  [[ $src == *'"https://github.com/xshowee/cc-pilot"'* ]] || fail "credits 应链接到项目主页"
  # credits 用到的每个本地化键都要有中文翻译
  local -a keys
  keys=(${(f)"$(grep -o 'String(localized: "[^"]*")' $ABOUT_SRC | sed 's/^String(localized: "//; s/")$//')"})
  (( ${#keys} )) || fail "AboutPanel.swift 里没有找到本地化文字"
  local key zh all_en= all_zh=
  for key in $keys; do
    zh=$(zh_string $ZH/Localizable.strings $key)
    [[ -n $zh ]] || fail "缺少中文翻译：$key"
    all_en+=$key all_zh+=$zh
  done
  [[ $all_en == *"MIT License"* ]] || fail "英文 credits 应写明 MIT License"
  [[ $all_zh == *"MIT 许可证"* ]] || fail "中文 credits 应写明 MIT 许可证"
}

t_main "$@"
