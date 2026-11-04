#!/bin/zsh -f
# ccp chatgpt ls（别名 ccp codex ls）：列出 ChatGPT 档案并标出当前档案（chatgpt-profiles ticket 02）。
# 档案：默认档案 ~/.codex，其他档案 ~/.codex-profiles/<名字>/，当前档案记录 ~/.codex-profiles/active。
# 输出格式与 ccp ls 相同；Claude 侧的 ccp ls 不受影响。
source "${0:A:h}/lib.zsh"

test_ls_without_profiles_lists_only_default_as_current() {
  t_codex_default
  t_ccp chatgpt ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "* default" "ccp chatgpt ls"
}

test_ls_lists_default_first_then_sorted_profiles_and_marks_current() {
  t_codex_default
  t_codex_profile work personal Alpha
  t_codex_active personal
  t_ccp chatgpt ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "  default
  Alpha
* personal
  work" "ccp chatgpt ls"
}

test_codex_is_an_alias_of_chatgpt() {
  t_codex_default
  t_codex_profile work
  t_codex_active work
  t_ccp codex ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "  default
* work" "ccp codex ls"
}

test_ls_explicit_default_record_marks_default() {
  t_codex_profile work
  t_codex_active default
  t_ccp chatgpt ls
  assert_rc 0
  assert_eq "$T_OUT" "* default
  work" "ccp chatgpt ls"
}

test_ls_skips_record_temp_files_hidden_and_invalid_entries() {
  t_codex_profile work
  t_codex_active work
  mkdir -p -- "$T_HOME/.codex-profiles/.hidden" "$T_HOME/.codex-profiles/a b" \
    "$T_HOME/.codex-profiles/default"
  : > "$T_HOME/.codex-profiles/.active.Ab12Cd"
  : > "$T_HOME/.codex-profiles/plainfile"
  mkdir -p -- "$T/elsewhere"
  ln -s -- "$T/elsewhere" "$T_HOME/.codex-profiles/linked"
  ln -s -- "$T/nowhere" "$T_HOME/.codex-profiles/dangling"
  t_ccp chatgpt ls
  assert_rc 0
  assert_eq "$T_OUT" "  default
  linked
* work" "ccp chatgpt ls"
}

test_ls_shows_no_account_information() {
  t_codex_default
  t_codex_profile work
  print -r -- '{"auth_mode":"chatgpt","tokens":{"id_token":"x.eyJlbWFpbCI6InNvbWVvbmVAZXhhbXBsZS5jb20ifQ.y","access_token":"secret-token","account_id":"acc"}}' \
    > "$T_HOME/.codex-profiles/work/auth.json"
  t_ccp chatgpt ls
  assert_rc 0
  [[ $T_OUT$T_ERR != *@* && $T_OUT$T_ERR != *secret* ]] || fail "ccp chatgpt ls 不应显示账号信息"
}

test_ls_warns_when_current_profile_is_missing() {
  t_codex_profile work
  t_codex_active gone
  t_ccp chatgpt ls
  assert_rc 0
  assert_eq "$T_OUT" "  default
  work" "ccp chatgpt ls"
  assert_contains "$T_ERR" gone "stderr 应提到不存在的当前档案"
  assert_contains "$T_ERR" "ccp chatgpt use default" "stderr 里应有 ChatGPT 的修复建议"
}

test_ls_warns_when_current_profile_name_is_invalid() {
  t_codex_active "a b"
  t_ccp chatgpt ls
  assert_rc 0
  assert_eq "$T_OUT" "  default" "ccp chatgpt ls"
  assert_contains "$T_ERR" "不合规" "stderr 应说明名字不合规"
}

test_ls_does_not_create_or_change_files() {
  t_ccp chatgpt ls
  assert_rc 0
  [[ ! -e $T_HOME/.codex-profiles && ! -e $T_HOME/.codex ]] || fail "ccp chatgpt ls 不应创建任何目录"
}

test_ls_with_extra_argument_prints_usage() {
  t_ccp chatgpt ls -l
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
}

test_chatgpt_without_subcommand_prints_usage_and_fails() {
  t_ccp chatgpt
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
  assert_contains "$T_ERR" "ls" "用法说明里应列出 ls"
}

test_chatgpt_unknown_subcommand_prints_usage_and_fails() {
  t_ccp codex frobnicate
  assert_rc 2
  assert_contains "$T_ERR" frobnicate "错误信息里应有那个未知命令"
  assert_contains "$T_ERR" "用法" "应输出用法说明"
}

test_chatgpt_help_succeeds() {
  t_ccp chatgpt --help
  assert_rc 0
  assert_contains "$T_OUT" "ls" "用法说明里应列出 ls"
}

test_claude_ls_ignores_chatgpt_profiles() {
  t_codex_profile work
  t_codex_active work
  t_profile personal
  t_ccp ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "* default
  personal" "ccp ls 只列 Claude 档案"
}

test_chatgpt_ls_ignores_claude_profiles() {
  t_profile personal
  t_active personal
  t_ccp chatgpt ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "* default" "ccp chatgpt ls 只列 ChatGPT 档案"
}

t_main "$@"
