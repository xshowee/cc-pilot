#!/bin/zsh -f
# ticket 14：scripts/release.sh 的发布前检查。
#
# 正式发布前必须先拦下"Sparkle 公钥还是占位值"和"钥匙串里的私钥与公钥不匹配"，
# 而且要在下载 Sparkle、编译之前就拦下（不联网、不留下构建产物）。
# 每个用例把 scripts/ 和 Resources/ 复制到临时目录里运行，Sparkle 指向一个假目录，
# 其中的 bin/generate_keys 是 tests/fakes/fake-generate-keys。
source "${0:A:h}/lib.zsh"

PLACEHOLDER_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
REAL_LOOKING_KEY=pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=
OTHER_KEY=Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMTI=

# 在 $T/repo 里放一份可运行的 release.sh，Sparkle 指向 $T/sparkle（假的）
setup_repo() {
  mkdir -p -- $T/repo $T/sparkle/bin $T/sparkle/Sparkle.framework || exit 1
  cp -R -- $ROOT/scripts $ROOT/Resources $T/repo/ || exit 1
  ln -s -- $FAKES/fake-generate-keys $T/sparkle/bin/generate_keys || exit 1
}

set_public_key() {
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $1" $T/repo/Resources/Info.plist > /dev/null || exit 1
}

run_release() {  # [VAR=值 ...]
  t_run CCP_SPARKLE_DIR=$T/sparkle FAKE_GENERATE_KEYS_LOG=$T/keys.log "$@" -- \
    /bin/zsh -f $T/repo/scripts/release.sh
}

assert_nothing_built() {
  [[ ! -e $T/repo/build/obj && ! -e "$T/repo/build/CC Pilot.app" ]] || fail "不应开始编译"
}

test_refuses_while_public_key_is_placeholder() {
  setup_repo
  set_public_key $PLACEHOLDER_KEY
  run_release FAKE_GENERATE_KEYS_PUBLIC=$PLACEHOLDER_KEY
  assert_rc_nonzero
  assert_contains "$T_ERR" SUPublicEDKey "错误信息应指出是 SUPublicEDKey"
  assert_contains "$T_ERR" "generate_keys --account cc-pilot" "错误信息应给出生成密钥的命令"
  assert_nothing_built
}

test_repository_info_plist_ships_with_placeholder_and_is_refused() {
  # 仓库里的 Info.plist 交付时就是占位值（密钥由用户亲自生成），直接运行也必须被拦下
  setup_repo
  run_release
  assert_rc_nonzero
  assert_contains "$T_ERR" SUPublicEDKey "错误信息应指出是 SUPublicEDKey"
  assert_nothing_built
}

test_refuses_when_keychain_has_no_cc_pilot_key() {
  setup_repo
  set_public_key $REAL_LOOKING_KEY
  run_release   # 假 generate_keys 未设置公钥：模拟钥匙串里没有私钥
  assert_rc_nonzero
  assert_contains "$T_ERR" "私钥" "错误信息应说明缺少私钥"
  assert_nothing_built
}

test_refuses_when_keychain_key_does_not_match_info_plist() {
  setup_repo
  set_public_key $REAL_LOOKING_KEY
  run_release FAKE_GENERATE_KEYS_PUBLIC=$OTHER_KEY
  assert_rc_nonzero
  assert_contains "$T_ERR" "不匹配" "错误信息应说明公钥不匹配"
  assert_nothing_built
}

test_looks_up_key_under_cc_pilot_account_only() {
  # 用户决定：cc-pilot 的密钥单独存放在 --account cc-pilot 下，不用默认账户
  setup_repo
  set_public_key $REAL_LOOKING_KEY
  run_release FAKE_GENERATE_KEYS_PUBLIC=$OTHER_KEY
  local log=$(< $T/keys.log)
  assert_contains "$log" $'arg=--account\narg=cc-pilot' "generate_keys 应带 --account cc-pilot"
  assert_contains "$log" "arg=-p" "只应查询公钥（-p），不应生成新密钥"
}

test_local_dry_run_skips_keychain_key_check() {
  # CCP_SKIP_NOTARIZE=1 只用于在本机验证打包流程：不查钥匙串里的 Sparkle 私钥，占位公钥只警告。
  # 这里只看它越过了密钥检查；随后用一个不存在的签名身份让它在编译前失败。
  setup_repo
  # 假 security：钥匙串里一个签名身份也没有（不碰真实钥匙串）
  mkdir -p -- $T/bin || exit 1
  print -r -- $'#!/bin/zsh -f\n[[ $1 == find-identity ]] && { print "     0 valid identities found"; exit 0 }\nexit 1' \
    > $T/bin/security && chmod +x $T/bin/security || exit 1
  run_release PATH=$T/bin:$FAKES:/usr/bin:/bin:/usr/sbin:/sbin \
    CCP_SKIP_NOTARIZE=1 CCP_RELEASE_IDENTITY=no-such-identity
  [[ ! -e $T/keys.log ]] || fail "本地验证模式不应调用 generate_keys"
  assert_contains "$T_ERR" "占位" "应提示公钥仍是占位值"
  assert_contains "$T_ERR" "no-such-identity" "应在检查签名身份时失败"
  assert_rc_nonzero
  assert_nothing_built
}

t_main "$@"
