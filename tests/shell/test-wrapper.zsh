#!/bin/zsh -f
# claude 包装函数：决定会话使用哪个档案（ticket 01）
source "${0:A:h}/lib.zsh"

# ---------- 3. 当前档案记录 ----------

test_no_active_record_runs_default_profile_with_args_untouched() {
  t_claude -- "a b" "" --x -p
  assert_rc 0
  assert_stderr_empty
  assert_claude_calls 1
  assert_claude_config_dir_unset
  assert_claude_args "a b" "" --x -p
}

test_active_default_runs_default_profile() {
  t_profile work
  t_active default
  t_claude -- hello
  assert_rc 0
  assert_stderr_empty
  assert_claude_calls 1
  assert_claude_config_dir_unset
  assert_claude_args hello
}

test_empty_active_record_runs_default_profile() {
  mkdir -p -- "$T_HOME/.claude-profiles"
  : > "$T_HOME/.claude-profiles/active"
  t_claude
  assert_rc 0
  assert_stderr_empty
  assert_claude_config_dir_unset
  assert_claude_args
}

test_active_profile_sets_absolute_config_dir() {
  t_profile work
  t_active work
  t_claude -- --resume "x y"
  assert_rc 0
  assert_stderr_empty
  assert_claude_calls 1
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args --resume "x y"
}

test_config_dir_has_no_trailing_slash_even_if_home_ends_with_slash() {
  t_profile work
  t_active work
  t_claude HOME="$T_HOME/"
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
}

test_active_record_tolerates_surrounding_whitespace() {
  t_profile work
  mkdir -p -- "$T_HOME/.claude-profiles"
  printf 'work \r\n' > "$T_HOME/.claude-profiles/active"
  t_claude
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
}

test_missing_active_profile_fails_with_hint_and_does_not_run_claude() {
  t_active gone
  t_claude -- a
  assert_rc_nonzero
  assert_contains "$T_ERR" gone "错误信息里应有档案名"
  assert_contains "$T_ERR" "ccp use default" "错误信息里应有修复建议"
  assert_claude_calls 0
}

test_active_name_differing_only_in_case_counts_as_missing() {
  # 只有 work 目录时，记录里的 Work 不能用：否则 CLAUDE_CONFIG_DIR 是 .../Work，钥匙串项对不上
  t_profile work
  t_active Work
  t_claude
  assert_rc_nonzero
  assert_contains "$T_ERR" Work "错误信息里应有档案名"
  assert_claude_calls 0
  t_claude CLAUDE_PROFILE=Work
  assert_rc_nonzero
  assert_claude_calls 0
}

test_active_record_naming_a_non_directory_counts_as_missing() {
  # 内容为 active：拼出来的路径就是记录文件本身，不是档案目录；active 是保留名
  t_active active
  t_claude
  assert_rc_nonzero
  assert_contains "$T_ERR" "保留名" "错误信息"
  assert_claude_calls 0
}

# ---------- 2. CLAUDE_PROFILE ----------

test_claude_profile_overrides_active_record() {
  t_profile work personal
  t_active work
  t_claude CLAUDE_PROFILE=personal -- a
  assert_rc 0
  assert_stderr_empty
  assert_claude_config_dir "$T_HOME/.claude-profiles/personal"
  assert_claude_args a
}

test_claude_profile_overrides_missing_active_profile() {
  # 当前档案记录指向不存在的档案也不影响：根本不读它
  t_profile personal
  t_active gone
  t_claude CLAUDE_PROFILE=personal
  assert_rc 0
  assert_stderr_empty
  assert_claude_config_dir "$T_HOME/.claude-profiles/personal"
}

test_claude_profile_default_does_not_set_config_dir() {
  t_profile work
  t_active work
  t_claude CLAUDE_PROFILE=default
  assert_rc 0
  assert_stderr_empty
  assert_claude_config_dir_unset
}

test_empty_claude_profile_falls_back_to_active_record() {
  t_profile work
  t_active work
  t_claude CLAUDE_PROFILE=
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
}

test_missing_claude_profile_fails_with_hint_and_does_not_run_claude() {
  t_profile work
  t_active work
  t_claude CLAUDE_PROFILE=gone
  assert_rc_nonzero
  assert_contains "$T_ERR" gone "错误信息里应有档案名"
  assert_contains "$T_ERR" "unset CLAUDE_PROFILE" "错误信息里应有修复建议"
  assert_claude_calls 0
}

test_invalid_profile_name_is_rejected_even_if_path_exists() {
  # ../x 拼出来的目录真实存在，但名字不合规，不能被当成档案
  mkdir -p -- "$T_HOME/x"
  t_profile work
  t_claude CLAUDE_PROFILE=../x
  assert_rc_nonzero
  assert_contains "$T_ERR" "ccp ls" "错误信息里应有修复建议"
  assert_claude_calls 0

  t_active ../x
  t_claude
  assert_rc_nonzero
  assert_claude_calls 0
}

# ---------- 1. CLAUDE_CONFIG_DIR ----------

test_existing_config_dir_passes_through_without_reading_profiles() {
  # 当前档案记录和 CLAUDE_PROFILE 都指向不存在的档案：只要读了任何一个就会报错
  t_active missing-active
  t_claude CLAUDE_CONFIG_DIR=/x/y/ CLAUDE_PROFILE=missing-env -- a
  assert_rc 0
  assert_stderr_empty
  assert_claude_calls 1
  assert_claude_config_dir /x/y/
  assert_claude_args a
}

test_existing_empty_config_dir_passes_through() {
  t_profile work
  t_active work
  t_claude CLAUDE_CONFIG_DIR=
  assert_rc 0
  assert_claude_config_dir ""
}

# ---------- 调用真正的 Claude Code ----------

test_wrapper_does_not_recurse_and_runs_real_claude_once_per_call() {
  t_profile work
  t_active work
  t_zsh 'claude one; claude two'
  assert_rc 0
  assert_claude_calls 2
  assert_claude_config_dir "$T_HOME/.claude-profiles/work" 1
  assert_claude_config_dir "$T_HOME/.claude-profiles/work" 2
}

test_wrapper_returns_claude_exit_status() {
  t_claude FAKE_CLAUDE_EXIT=7
  assert_rc 7
  assert_claude_calls 1
}

test_existing_env_based_claude_functions_are_unaffected() {
  # 用户已有的函数用 `env … claude` 启动 Claude Code，env 不经过 shell 函数
  t_profile work
  t_active work
  t_zsh 'third() { env ANTHROPIC_BASE_URL=https://example.invalid claude "$@" }; third q'
  assert_rc 0
  assert_stderr_empty
  assert_claude_calls 1
  assert_claude_config_dir_unset
  assert_claude_args q
}

test_wrapper_does_not_leave_config_dir_in_user_shell() {
  t_profile work
  t_active work
  t_zsh 'claude; print -r -- "after=${CLAUDE_CONFIG_DIR-unset}"'
  assert_rc 0
  assert_eq "$T_OUT" "after=unset" "包装函数不应把 CLAUDE_CONFIG_DIR 留在用户 shell 里"
}

test_wrapper_works_under_unusual_user_options() {
  t_profile work
  t_active work
  t_zsh 'setopt ksh_arrays sh_word_split nounset no_glob; claude "a b" c'
  assert_rc 0
  assert_stderr_empty
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args "a b" c
}

# ---------- 入口文件 cc-pilot.zsh ----------

test_sourcing_entry_only_adds_claude_and_private_names() {
  t_run -- /bin/zsh -f -c '
    before_f=(${(k)functions}); before_p=(${(k)parameters})
    source "$HOME/.cc-pilot/cc-pilot.zsh" || exit 98
    for f in ${(k)functions}; do (( ${before_f[(Ie)$f]} )) || print -r -- "function $f"; done
    for p in ${(k)parameters}; do
      [[ $p == (before_f|before_p|f|p) ]] && continue
      (( ${before_p[(Ie)$p]} )) || print -r -- "param $p"
    done'
  assert_rc 0
  local line
  for line in ${(f)T_OUT}; do
    [[ $line == ("function claude"|"function _ccp_"*) ]] || fail "source 后多出了 [$line]"
  done
  assert_contains "$T_OUT" "function claude" "应定义 claude 函数"
}

test_sourcing_entry_puts_installed_bin_on_path_once() {
  t_zsh 'source "$HOME/.cc-pilot/cc-pilot.zsh"; print -rl -- $path; print -r -- "ccp=$(whence -p ccp)"'
  assert_rc 0
  local -a lines hits
  lines=("${(@f)T_OUT}")
  hits=("${(@M)lines:#"$T_HOME/.cc-pilot/bin"}")
  assert_eq "${lines[1]}" "$T_HOME/.cc-pilot/bin" "PATH 第一项"
  assert_eq "${#hits}" 1 "bin 只应出现一次"
  assert_eq "${lines[-1]}" "ccp=$T_HOME/.cc-pilot/bin/ccp" "ccp 应能在 PATH 中找到"
}

t_main "$@"
