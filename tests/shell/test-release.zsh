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

test_repository_info_plist_ships_real_public_key() {
  # 用户已用 generate_keys --account cc-pilot 生成密钥并填入公钥：仓库里的值不能是占位值，
  # 且必须是 32 字节 Ed25519 公钥的 base64
  local key bytes
  key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" $ROOT/Resources/Info.plist) || fail "读不到 SUPublicEDKey"
  [[ $key != $PLACEHOLDER_KEY ]] || fail "SUPublicEDKey 仍是占位值"
  bytes=$(print -rn -- $key | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c)
  (( bytes == 32 )) || fail "SUPublicEDKey 解码后应为 32 字节，实际 ${bytes// /} 字节"
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
  set_public_key $PLACEHOLDER_KEY
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

# 假 security：find-identity 输出给定的几行（不碰真实钥匙串）
fake_identities() {
  mkdir -p -- $T/bin || exit 1
  { print -r -- '#!/bin/zsh -f'
    print -r -- '[[ $1 == find-identity ]] || exit 1'
    print -r -- "print -r -- ${(q)1}"
  } > $T/bin/security && chmod +x $T/bin/security || exit 1
}

test_reads_settings_from_dot_env() {
  # .env 里的 CCP_* 变量等同于环境变量；空值当作没写，不执行其中的命令
  setup_repo
  set_public_key $PLACEHOLDER_KEY
  fake_identities '     0 valid identities found'
  print -r -l -- '# 注释' 'CCP_SKIP_NOTARIZE=1' 'CCP_TEAM_ID=' 'CCP_RELEASE_IDENTITY="from-dot-env"' \
    'touch should-not-exist' > $T/repo/.env
  run_release PATH=$T/bin:$FAKES:/usr/bin:/bin:/usr/sbin:/sbin
  assert_contains "$T_ERR" "from-dot-env" "应使用 .env 里的签名身份（引号已去掉）"
  [[ ! -e $T/repo/should-not-exist ]] || fail "不应执行 .env 里的命令"
  assert_rc_nonzero
  assert_nothing_built
}

test_command_line_overrides_dot_env() {
  setup_repo
  set_public_key $PLACEHOLDER_KEY
  fake_identities '     0 valid identities found'
  print -r -l -- 'CCP_SKIP_NOTARIZE=1' 'CCP_RELEASE_IDENTITY=from-dot-env' > $T/repo/.env
  run_release PATH=$T/bin:$FAKES:/usr/bin:/bin:/usr/sbin:/sbin CCP_RELEASE_IDENTITY=from-command-line
  assert_contains "$T_ERR" "from-command-line" "命令行里的签名身份应优先"
  [[ $T_ERR != *from-dot-env* ]] || fail "不应使用 .env 里的签名身份"
  assert_rc_nonzero
}

test_requires_team_id_when_keychain_has_several_teams() {
  setup_repo
  set_public_key $PLACEHOLDER_KEY
  fake_identities $'  1) AAAA1111 "Developer ID Application: A (TEAMAAAAAA)"\n  2) BBBB2222 "Developer ID Application: B (TEAMBBBBBB)"\n     2 valid identities found'
  run_release PATH=$T/bin:$FAKES:/usr/bin:/bin:/usr/sbin:/sbin CCP_SKIP_NOTARIZE=1
  assert_contains "$T_ERR" "CCP_TEAM_ID" "应要求用 CCP_TEAM_ID 指定团队"
  assert_rc_nonzero
  assert_nothing_built
}

t_main "$@"
