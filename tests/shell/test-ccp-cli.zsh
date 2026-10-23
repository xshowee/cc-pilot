#!/bin/zsh -f
# ccp 命令的分派与用法说明（ticket 01 的骨架；各子命令的行为由各自的测试文件覆盖）
source "${0:A:h}/lib.zsh"

typeset -ga CCP_COMMANDS=(ls current use add rm init uninstall)

assert_usage_lists_all_commands() {  # 文本
  local c
  assert_contains "$1" "用法" "应输出用法说明"
  for c in $CCP_COMMANDS; do
    [[ $1 == *$'\n'"  $c"[[:space:]]* ]] || fail "用法说明里没有列出 $c"
  done
}

test_no_arguments_prints_usage_and_fails() {
  t_ccp
  assert_rc_nonzero
  assert_usage_lists_all_commands "$T_OUT"$'\n'"$T_ERR"
}

test_unknown_command_prints_usage_and_fails() {
  t_ccp -- frobnicate
  assert_rc_nonzero
  assert_contains "$T_ERR" frobnicate "错误信息里应有那个未知命令"
  assert_usage_lists_all_commands "$T_OUT"$'\n'"$T_ERR"
}

test_help_prints_usage_and_succeeds() {
  local flag
  for flag in help -h --help; do
    t_ccp -- $flag
    assert_rc 0
    assert_usage_lists_all_commands "$T_OUT"
  done
}

test_every_command_is_dispatched_not_reported_unknown() {
  local c
  for c in $CCP_COMMANDS; do
    t_ccp -- $c
    [[ $T_ERR != *未知命令* ]] || fail "ccp $c 被当成了未知命令"
  done
}

test_ccp_is_runnable_through_path_after_sourcing_entry() {
  t_zsh 'ccp --help'
  assert_rc 0
  assert_usage_lists_all_commands "$T_OUT"
}

t_main "$@"
