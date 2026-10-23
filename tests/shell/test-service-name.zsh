#!/bin/zsh -f
# 钥匙串 service 名计算函数 _ccp_service_name（ticket 01）。
# 期望值来自两端共用的测试向量 tests/fixtures/service-names.tsv。
source "${0:A:h}/lib.zsh"

# 调用已安装的 shell/lib/keychain.zsh 里的函数：service_name [VAR=值 ...] [--] [配置目录]
service_name() {
  local -a extra
  while [[ ${1-} == [A-Za-z_][A-Za-z0-9_]#=* ]]; do extra+=("$1"); shift; done
  [[ ${1-} == -- ]] && shift
  t_run "${extra[@]}" -- /bin/zsh -f -c \
    'source "$HOME/.cc-pilot/lib/keychain.zsh" || exit 98; _ccp_service_name "$@"' _ "$@"
}

# 十六进制 → 原始字节
from_hex() {
  local hex=$1
  printf "${hex//(#m)??/\\x$MATCH}"
}

check_vectors() {  # 额外的环境变量...
  local line hex want note input
  integer count=0
  while IFS=$'\t' read -r hex want note; do
    [[ -z $hex || $hex == \#* ]] && continue
    if [[ $hex == - ]]; then
      service_name "$@" --
    else
      input=$(from_hex $hex)
      service_name "$@" -- "$input"
    fi
    assert_rc 0
    assert_stderr_empty
    assert_eq "$T_OUT" "$want" "$note（$*）"
    (( count++ ))
  done < $FIXTURES/service-names.tsv
  (( count >= 6 )) || fail "测试向量太少：$count"
}

test_vectors_match_in_utf8_locale() {
  check_vectors LANG=en_US.UTF-8
}

test_vectors_match_in_c_locale() {
  check_vectors LANG=C LC_ALL=C
}

test_default_profile_has_no_suffix() {
  service_name
  assert_rc 0
  assert_eq "$T_OUT" "Claude Code-credentials" "默认档案"
}

test_other_profile_has_eight_hex_suffix() {
  service_name -- "$T_HOME/.claude-profiles/work"
  assert_rc 0
  [[ $T_OUT == "Claude Code-credentials-"[0-9a-f](#c8) ]] || fail "格式不对：[$T_OUT]"
}

test_trailing_slash_changes_the_result() {
  local without with
  service_name -- /Users/test/.claude-profiles/work
  without=$T_OUT
  service_name -- /Users/test/.claude-profiles/work/
  with=$T_OUT
  assert_ne "$with" "$without" "结尾带 / 与不带 / 的结果"
}

test_nfd_and_nfc_spellings_give_the_same_result() {
  local nfd nfc
  service_name -- "$(from_hex 2f55736572732f4a6f7365cc812f2e636c617564652d70726f66696c65732f776f726b)"
  assert_rc 0
  nfd=$T_OUT
  service_name -- "$(from_hex 2f55736572732f4a6f73c3a92f2e636c617564652d70726f66696c65732f776f726b)"
  assert_rc 0
  nfc=$T_OUT
  assert_eq "$nfd" "$nfc" "NFD 与 NFC 写法"
}

t_main "$@"
