#!/bin/zsh -f
# ccp rm：确认 → 在档案里登出 → 确认钥匙串项已不存在 → 删除档案目录（ticket 04）
source "${0:A:h}/lib.zsh"

# 01 的函数为某个配置目录算出的钥匙串 service 名（被测的 rm 必须用同一个值查询）
service_for() {
  local out
  out=$(env -i HOME=$T_HOME PATH=/usr/bin:/bin /bin/zsh -f -c \
    'source "$HOME/.cc-pilot/lib/keychain.zsh" || exit 98; _ccp_service_name "$1"' _ "$1") \
    || fail "无法计算 $1 的 service 名"
  [[ $out == "Claude Code-credentials-"[0-9a-f](#c8) ]] || fail "service 名格式不对：$out"
  print -r -- "$out"
}

assert_profile_intact() {  # 名字
  [[ -d $T_HOME/.claude-profiles/$1 ]] || fail "档案目录 $1 应保持原样"
  [[ -f $T_HOME/.claude-profiles/$1/.claude.json ]] || fail "档案 $1 里的文件应保持原样"
}

assert_nothing_launched() {
  assert_claude_calls 0
  assert_eq "$(security_calls)" 0 "假 security 的调用次数"
}

# 档案目录里放一个独有文件，便于检查"保持原样"
t_profile_with_data() {
  t_profile "$@"
  local n
  for n in "$@"; do print -r -- '{}' > "$T_HOME/.claude-profiles/$n/.claude.json"; done
}

# ---------- 确认 ----------

test_logged_out_profile_is_deleted_after_confirmation() {
  t_profile_with_data work
  t_stdin y
  t_ccp -- rm work
  assert_rc 0
  [[ ! -e $T_HOME/.claude-profiles/work ]] || fail "档案目录应已删除"
}

test_full_word_yes_also_confirms() {
  t_profile_with_data work
  t_stdin YES
  t_ccp -- rm work
  assert_rc 0
  [[ ! -e $T_HOME/.claude-profiles/work ]] || fail "档案目录应已删除"
}

test_asks_for_confirmation_naming_the_profile() {
  t_profile_with_data work
  t_stdin n
  t_ccp -- rm work
  assert_contains "$T_ERR" '"work"' "确认提示里应有档案名"
  assert_contains "$T_ERR" "[y/N]" "应询问用户"
}

test_declining_does_nothing() {
  local answer
  for answer in n no "" "yes please"; do
    t_profile_with_data work
    t_stdin "$answer"
    t_ccp -- rm work
    assert_rc_nonzero
    assert_profile_intact work
    assert_nothing_launched
  done
}

test_no_input_counts_as_declining() {
  # 标准输入是 /dev/null：读不到回答
  t_profile_with_data work
  t_ccp -- rm work
  assert_rc_nonzero
  assert_profile_intact work
  assert_nothing_launched
}

# ---------- 登出 ----------

test_launches_claude_code_of_the_removed_profile() {
  t_profile_with_data work personal
  t_active personal
  t_stdin y
  t_ccp -- rm work
  assert_rc 0
  assert_claude_calls 1
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args
}

test_config_dir_is_normalized_even_if_home_ends_with_slash() {
  t_profile_with_data work
  t_stdin y
  t_ccp HOME="$T_HOME/" -- rm work
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
}

test_queries_keychain_for_the_profile_service_without_reading_password() {
  t_profile_with_data work
  t_stdin y
  t_ccp -- rm work
  assert_rc 0
  assert_eq "$(security_calls)" 1 "假 security 的调用次数"
  local -a reply
  security_args
  assert_eq "${reply[1]}" find-generic-password "security 子命令"
  local svc i found=0
  svc=$(service_for "$T_HOME/.claude-profiles/work")
  for (( i = 2; i <= ${#reply}; i++ )); do
    [[ ${reply[i]} == -s && ${reply[i+1]-} == "$svc" ]] && found=1
  done
  (( found )) || fail "security 参数 [${(j:|:)reply}] 里应有 -s $svc"
  (( ! ${reply[(Ie)-w]} )) || fail "查询参数里不应有 -w：[${(j:|:)reply}]"
  (( ! ${reply[(Ie)-g]} )) || fail "查询参数里不应有 -g：[${(j:|:)reply}]"
}

test_still_logged_in_profile_is_not_deleted() {
  t_profile_with_data work
  t_keychain_item "$(service_for "$T_HOME/.claude-profiles/work")" tester '{"claudeAiOauth":{}}'
  t_stdin y
  t_ccp -- rm work
  assert_rc_nonzero
  assert_profile_intact work
  assert_claude_calls 1
  assert_contains "$T_ERR" /logout "应提示在该档案里执行 /logout"
  assert_contains "$T_ERR" work "提示里应有档案名"
  [[ $T_OUT$T_ERR != *claudeAiOauth* ]] || fail "不应输出凭据内容"
}

test_logout_inside_claude_code_lets_deletion_proceed() {
  # 一开始还登录着；用户在打开的 Claude Code 里 /logout（假 claude 删掉钥匙串项）
  t_profile_with_data work
  local svc
  svc=$(service_for "$T_HOME/.claude-profiles/work")
  t_keychain_item "$svc" tester secret
  t_stdin y
  t_ccp FAKE_CLAUDE_HOOK="rm -rf -- \"\$FAKE_SECURITY_DIR/items/$svc\"" -- rm work
  assert_rc 0
  [[ ! -e $T_HOME/.claude-profiles/work ]] || fail "档案目录应已删除"
}

test_other_profiles_keychain_items_do_not_block_deletion() {
  t_profile_with_data work personal
  t_keychain_item "Claude Code-credentials" root secret
  t_keychain_item "$(service_for "$T_HOME/.claude-profiles/personal")" tester secret
  t_stdin y
  t_ccp -- rm work
  assert_rc 0
  [[ ! -e $T_HOME/.claude-profiles/work ]] || fail "档案目录应已删除"
  assert_profile_intact personal
}

test_keychain_query_failure_is_not_treated_as_logged_out() {
  t_profile_with_data work
  t_stdin y
  t_ccp FAKE_SECURITY_EXIT=51 -- rm work
  assert_rc_nonzero
  assert_profile_intact work
}

# ---------- 删除 ----------

test_deletes_symlinks_but_keeps_shared_resources_in_default_profile() {
  local d=$T_HOME/.claude p=$T_HOME/.claude-profiles/work
  mkdir -p -- $d/skills/my-skill $d/projects/proj $d/plugins
  print -r -- '{"theme":"dark"}' > $d/settings.json
  print -r -- skill > $d/skills/my-skill/SKILL.md
  print -r -- session > $d/projects/proj/s.jsonl
  t_profile_with_data work
  ln -s -- $d/settings.json $p/settings.json
  ln -s -- $d/skills $p/skills
  ln -s -- $d/projects $p/projects
  ln -s -- $d/plugins $p/plugins
  t_stdin y
  t_ccp -- rm work
  assert_rc 0
  [[ ! -e $p && ! -L $p ]] || fail "档案目录应已删除"
  assert_eq "$(< $d/settings.json)" '{"theme":"dark"}' "默认档案的 settings.json"
  assert_eq "$(< $d/skills/my-skill/SKILL.md)" skill "默认档案的技能"
  assert_eq "$(< $d/projects/proj/s.jsonl)" session "默认档案的项目会话历史"
  [[ -d $d/plugins ]] || fail "默认档案的 plugins/ 应保留"
}

test_other_profiles_and_active_record_are_untouched() {
  t_profile_with_data work personal
  t_active personal
  t_stdin y
  t_ccp -- rm work
  assert_rc 0
  assert_profile_intact personal
  assert_eq "$(< $T_HOME/.claude-profiles/active)" personal "当前档案记录"
}

# ---------- 不能删除的情况 ----------

test_default_profile_cannot_be_removed() {
  mkdir -p -- $T_HOME/.claude
  print -r -- '{}' > $T_HOME/.claude/settings.json
  t_profile_with_data default  # 即使恰好有一个叫 default 的目录
  t_stdin y
  t_ccp -- rm default
  assert_rc_nonzero
  assert_contains "$T_ERR" 默认档案 "错误信息"
  [[ -f $T_HOME/.claude/settings.json ]] || fail "默认档案应保持原样"
  assert_profile_intact default
  assert_nothing_launched
}

test_current_profile_cannot_be_removed() {
  t_profile_with_data work
  t_active work
  t_stdin y
  t_ccp -- rm work
  assert_rc_nonzero
  assert_contains "$T_ERR" 当前档案 "错误信息"
  assert_contains "$T_ERR" "ccp use" "应提示先切换到别的档案"
  assert_profile_intact work
  assert_nothing_launched
}

test_current_profile_is_recognized_despite_whitespace_in_record() {
  t_profile_with_data work
  mkdir -p -- "$T_HOME/.claude-profiles"
  printf 'work \r\n' > "$T_HOME/.claude-profiles/active"
  t_stdin y
  t_ccp -- rm work
  assert_rc_nonzero
  assert_profile_intact work
  assert_nothing_launched
}

test_current_profile_recorded_with_different_case_cannot_be_removed() {
  # 记录里是 Work（手写或旧版本写入），磁盘上是 work：两者是同一个目录，仍是当前档案
  t_profile_with_data work
  t_active Work
  t_stdin y
  t_ccp -- rm work
  assert_rc_nonzero
  assert_contains "$T_ERR" 当前档案 "错误信息"
  assert_profile_intact work
  assert_nothing_launched
}

test_name_must_match_the_profile_directory_case_exactly() {
  t_profile_with_data work
  t_stdin y
  t_ccp -- rm Work
  assert_rc_nonzero
  assert_contains "$T_ERR" 不存在 "错误信息"
  assert_profile_intact work
  assert_nothing_launched
}

test_missing_profile_fails() {
  t_profile_with_data personal
  t_stdin y
  t_ccp -- rm gone
  assert_rc_nonzero
  assert_contains "$T_ERR" gone "错误信息里应有档案名"
  assert_contains "$T_ERR" 不存在 "错误信息"
  assert_nothing_launched
}

test_active_record_file_is_not_a_profile() {
  t_profile_with_data personal
  t_active personal
  t_stdin y
  t_ccp -- rm active
  assert_rc_nonzero
  assert_eq "$(< $T_HOME/.claude-profiles/active)" personal "当前档案记录应保持原样"
  assert_nothing_launched
}

test_invalid_name_is_rejected_even_if_path_exists() {
  mkdir -p -- "$T_HOME/x"
  print -r -- keep > "$T_HOME/x/f"
  t_profile_with_data work
  t_stdin y
  t_ccp -- rm ../x
  assert_rc_nonzero
  [[ -f $T_HOME/x/f ]] || fail "档案目录之外的东西不能被删"
  assert_nothing_launched
}

test_wrong_number_of_arguments_prints_usage() {
  t_profile_with_data work personal
  t_stdin y
  t_ccp -- rm
  assert_rc_nonzero
  assert_contains "$T_ERR" "ccp rm <名字>" "应输出用法"
  t_ccp -- rm work personal
  assert_rc_nonzero
  assert_contains "$T_ERR" "ccp rm <名字>" "应输出用法"
  assert_profile_intact work
  assert_profile_intact personal
  assert_nothing_launched
}

t_main "$@"
