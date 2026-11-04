#!/bin/zsh -f
# codex 包装函数：决定 codex 使用哪个 ChatGPT 档案（chatgpt-profiles ticket 04，ADR 0005）。
# 优先级：CODEX_PROFILE > 用户直接指定的 CODEX_HOME > 当前档案记录 ~/.codex-profiles/active。
# CODEX_HOME 等于 ~/.codex 或位于 ~/.codex-profiles/ 之下时视为 cc-pilot 设置的（可能是从 launchd 继承的旧值），
# 按当前档案重设；默认档案不设 CODEX_HOME。
source "${0:A:h}/lib.zsh"

# ---------- 3. 当前档案记录 ----------

test_only_default_profile_runs_codex_untouched() {
  # 只有默认档案、环境里也没有 CODEX_HOME：与没装 cc-pilot 完全一样
  t_codex_default
  t_codex -- "a b" "" --x exec
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "" "包装函数不应输出任何东西"
  assert_codex_calls 1
  assert_codex_home_unset
  assert_codex_args "a b" "" --x exec
}

test_active_default_runs_default_profile() {
  t_codex_profile work
  t_codex_active default
  t_codex -- hello
  assert_rc 0
  assert_stderr_empty
  assert_codex_home_unset
  assert_codex_args hello
}

test_active_profile_sets_absolute_codex_home() {
  t_codex_profile work
  t_codex_active work
  t_codex -- resume "x y"
  assert_rc 0
  assert_stderr_empty
  assert_codex_calls 1
  assert_codex_home "$T_HOME/.codex-profiles/work"
  assert_codex_args resume "x y"
}

test_codex_home_has_no_trailing_slash_even_if_home_ends_with_slash() {
  t_codex_profile work
  t_codex_active work
  t_codex HOME="$T_HOME/"
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_active_record_tolerates_surrounding_whitespace() {
  t_codex_profile work
  mkdir -p -- "$T_HOME/.codex-profiles"
  printf 'work \r\n' > "$T_HOME/.codex-profiles/active"
  t_codex
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_missing_active_profile_fails_with_hint_and_does_not_run_codex() {
  t_codex_active gone
  t_codex -- a
  assert_rc_nonzero
  assert_contains "$T_ERR" gone "错误信息里应有档案名"
  assert_contains "$T_ERR" "ccp chatgpt use default" "错误信息里应有修复建议"
  assert_codex_calls 0
}

test_claude_record_is_not_used_for_codex() {
  t_profile work
  t_active work
  t_codex
  assert_rc 0
  assert_codex_home_unset
}

# ---------- 2. CODEX_HOME ----------

test_user_codex_home_outside_managed_paths_wins_over_record() {
  t_codex_profile work
  t_codex_active work
  mkdir -p -- "$T/mine"
  t_codex CODEX_HOME="$T/mine" -- x
  assert_rc 0
  assert_stderr_empty
  assert_codex_home "$T/mine"
  assert_codex_args x
}

test_empty_codex_home_counts_as_user_choice() {
  t_codex_profile work
  t_codex_active work
  t_codex CODEX_HOME=
  assert_codex_calls 1
  assert_codex_home ""
}

test_paths_that_only_look_similar_are_user_choices() {
  t_codex_profile work
  t_codex_active work
  local p
  for p in "$T_HOME/.codex-profiles-old/x" "$T_HOME/.codexx" "$T_HOME/.codex/sub" "$T/other/.codex-profiles/work"; do
    mkdir -p -- "$p"
    t_codex CODEX_HOME="$p"
    assert_rc 0
    assert_codex_home "$p"
  done
}

test_inherited_profile_home_follows_current_profile() {
  # 从 Dock 打开的终端继承了 launchd 里的旧值
  t_codex_profile old work
  t_codex_active work
  t_codex CODEX_HOME="$T_HOME/.codex-profiles/old"
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_inherited_profile_home_is_removed_when_current_is_default() {
  t_codex_profile old
  t_codex_active default
  local p
  for p in "$T_HOME/.codex-profiles/old" "$T_HOME/.codex-profiles/old/" "$T_HOME/.codex-profiles/gone"; do
    t_codex CODEX_HOME="$p" -- q
    assert_rc 0
    assert_stderr_empty
    assert_codex_home_unset
    assert_codex_args q
  done
}

test_inherited_default_home_follows_current_profile() {
  t_codex_profile work
  t_codex_active work
  local p
  for p in "$T_HOME/.codex" "$T_HOME/.codex/"; do
    t_codex CODEX_HOME="$p"
    assert_rc 0
    assert_codex_home "$T_HOME/.codex-profiles/work"
  done
}

test_inherited_default_home_is_removed_for_default_profile() {
  t_codex_default
  t_codex CODEX_HOME="$T_HOME/.codex"
  assert_rc 0
  assert_codex_home_unset
}

test_inherited_home_with_missing_current_profile_fails() {
  t_codex_profile old
  t_codex_active gone
  t_codex CODEX_HOME="$T_HOME/.codex-profiles/old"
  assert_rc_nonzero
  assert_contains "$T_ERR" gone "错误信息里应有档案名"
  assert_codex_calls 0
}

# ---------- 1. CODEX_PROFILE ----------

test_codex_profile_overrides_record() {
  t_codex_profile work personal
  t_codex_active work
  t_codex CODEX_PROFILE=personal -- a
  assert_rc 0
  assert_stderr_empty
  assert_codex_home "$T_HOME/.codex-profiles/personal"
  assert_codex_args a
}

test_codex_profile_overrides_user_codex_home() {
  t_codex_profile personal
  mkdir -p -- "$T/mine"
  t_codex CODEX_PROFILE=personal CODEX_HOME="$T/mine"
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/personal"
}

test_codex_profile_default_removes_any_codex_home() {
  t_codex_profile work
  t_codex_active work
  mkdir -p -- "$T/mine"
  local p
  for p in "$T/mine" "$T_HOME/.codex-profiles/work"; do
    t_codex CODEX_PROFILE=default CODEX_HOME="$p"
    assert_rc 0
    assert_codex_home_unset
  done
}

test_empty_codex_profile_is_ignored() {
  t_codex_profile work
  t_codex_active work
  t_codex CODEX_PROFILE=
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_missing_codex_profile_fails_without_running_codex() {
  t_codex_profile work
  t_codex_active work
  t_codex CODEX_PROFILE=gone
  assert_rc_nonzero
  assert_contains "$T_ERR" gone "错误信息里应有档案名"
  assert_contains "$T_ERR" "unset CODEX_PROFILE" "错误信息里应有修复建议"
  assert_codex_calls 0
}

test_malformed_codex_profile_fails_without_running_codex() {
  t_codex CODEX_PROFILE="../x"
  assert_rc_nonzero
  assert_codex_calls 0
}

# ---------- 调用真正的 codex ----------

test_wrapper_does_not_recurse_and_runs_real_codex_once_per_call() {
  t_codex_profile work
  t_codex_active work
  t_zsh 'codex one; codex two'
  assert_rc 0
  assert_codex_calls 2
  assert_codex_home "$T_HOME/.codex-profiles/work" 1
  assert_codex_home "$T_HOME/.codex-profiles/work" 2
}

test_wrapper_returns_codex_exit_status_on_every_path() {
  t_codex_profile work
  t_codex FAKE_CODEX_EXIT=7
  assert_rc 7
  t_codex_active work
  t_codex FAKE_CODEX_EXIT=8
  assert_rc 8
  t_codex_active default
  t_codex FAKE_CODEX_EXIT=9 CODEX_HOME="$T_HOME/.codex-profiles/work"
  assert_rc 9
}

test_wrapper_passes_stdin_through_on_every_path() {
  t_codex_profile work
  t_stdin "hello there"
  local hook='IFS= read -r line; print -r -- "got=$line"'
  t_codex FAKE_CODEX_HOOK="$hook"
  assert_eq "$T_OUT" "got=hello there" "默认档案"
  t_codex FAKE_CODEX_HOOK="$hook" CODEX_HOME="$T_HOME/.codex-profiles/work"
  assert_eq "$T_OUT" "got=hello there" "去掉继承的 CODEX_HOME 时"
  t_codex FAKE_CODEX_HOOK="$hook" CODEX_PROFILE=work
  assert_eq "$T_OUT" "got=hello there" "其他档案"
}

test_wrapper_does_not_change_codex_home_in_user_shell() {
  t_codex_profile work old
  t_codex_active work
  t_zsh 'codex; print -r -- "after=${CODEX_HOME-unset}"'
  assert_eq "$T_OUT" "after=unset" "包装函数不应把 CODEX_HOME 留在用户 shell 里"
  t_codex_active default
  t_zsh CODEX_HOME="$T_HOME/.codex-profiles/old" -- 'codex; print -r -- "after=${CODEX_HOME-unset}"'
  assert_eq "$T_OUT" "after=$T_HOME/.codex-profiles/old" "包装函数不应改动用户 shell 里的 CODEX_HOME"
}

test_existing_env_based_codex_calls_are_unaffected() {
  t_codex_profile work
  t_codex_active work
  t_zsh 'env OPENAI_BASE_URL=https://example.invalid codex q'
  assert_rc 0
  assert_codex_calls 1
  assert_codex_home_unset
  assert_codex_args q
}

test_wrapper_works_under_unusual_user_options() {
  t_codex_profile work
  t_codex_active default
  t_zsh CODEX_HOME="$T_HOME/.codex-profiles/work" -- 'setopt ksh_arrays sh_word_split nounset no_glob; codex "a b" c'
  assert_rc 0
  assert_stderr_empty
  assert_codex_home_unset
  assert_codex_args "a b" c
  t_codex_active work
  t_zsh 'setopt ksh_arrays sh_word_split nounset no_glob; codex "a b" c'
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_claude_wrapper_is_unaffected_by_codex_variables() {
  t_profile work
  t_active work
  t_codex_profile personal
  t_claude CODEX_PROFILE=personal CODEX_HOME="$T_HOME/.codex-profiles/personal"
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_codex_calls 0
}

t_main "$@"
