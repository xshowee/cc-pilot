#!/bin/zsh -f
# ticket 14：Sparkle 自动更新与联网的配置（Resources/Info.plist）。
#
# 这些都是"只有发布出去才能观察到"的行为，能在本地验证的就是写进 Info.plist 的配置：
# 自动检查默认开启、每天一次、不上报系统信息、appcast 必须签名、更新地址是 https 的 appcast。
source "${0:A:h}/lib.zsh"

PLIST=$ROOT/Resources/Info.plist
plist() { /usr/libexec/PlistBuddy -c "Print :$1" $PLIST 2>/dev/null }
PLACEHOLDER_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

test_automatic_update_checks_are_on_by_default_once_a_day() {
  # SUEnableAutomaticChecks 写进 Info.plist，Sparkle 就不会在第二次启动时弹窗询问
  assert_eq "$(plist SUEnableAutomaticChecks)" true "自动检查更新默认开启"
  assert_eq "$(plist SUScheduledCheckInterval)" 86400 "每天检查一次"
}

test_sparkle_sends_no_system_profile() {
  # App 只访问额度接口和 appcast：不让 Sparkle 在请求 appcast 时附带系统信息
  assert_eq "$(plist SUEnableSystemProfiling)" false "不上报系统信息"
}

test_feed_is_https_appcast_and_must_be_signed() {
  local feed=$(plist SUFeedURL)
  [[ $feed == https://*/appcast.xml ]] || fail "SUFeedURL 应为 https 的 appcast.xml：[$feed]"
  assert_eq "$(plist SURequireSignedFeed)" true "appcast 整体必须带 EdDSA 签名"
  assert_eq "$(plist SUVerifyUpdateBeforeExtraction)" true "解压前先校验更新包签名"
}

test_public_key_placeholder_is_the_same_everywhere() {
  # 占位值在 Info.plist、release.sh（拒绝发布）和 Updater.swift（不启动 Sparkle）三处必须一致
  local key=$(plist SUPublicEDKey)
  [[ -n $key ]] || fail "Info.plist 应有 SUPublicEDKey"
  [[ $(< $ROOT/scripts/release.sh) == *"PLACEHOLDER_KEY=$PLACEHOLDER_KEY"* ]] ||
    fail "release.sh 的占位值与测试不一致"
  [[ $(< $ROOT/Sources/App/Updater.swift) == *"\"$PLACEHOLDER_KEY\""* ]] ||
    fail "Updater.swift 的占位值与测试不一致"
}

test_app_sandbox_is_not_enabled() {
  # spec：App 通过子进程调用 /usr/bin/security 读凭据，不能启用 App Sandbox
  local -a entitlements
  entitlements=($ROOT/**/*.entitlements(N))
  local f
  for f in $entitlements; do
    [[ $(< $f) != *com.apple.security.app-sandbox* ]] || fail "$f 启用了 App Sandbox"
  done
  [[ $(< $ROOT/scripts/build-app.sh) != *--entitlements* ]] || fail "build-app.sh 不应附加 entitlements"
}

t_main "$@"
