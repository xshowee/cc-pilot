#!/bin/zsh -f
# ccp current / ls / use：查看和切换当前档案（ticket 02）
source "${0:A:h}/lib.zsh"

# ---------- ccp ls ----------

test_ls_without_profiles_lists_only_default_as_current() {
  t_ccp ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "* default" "ccp ls"
}

test_ls_lists_default_first_then_sorted_profiles_and_marks_current() {
  t_profile work personal Alpha
  t_active personal
  t_ccp ls
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "  default
  Alpha
* personal
  work" "ccp ls"
}

test_ls_skips_record_temp_files_hidden_and_invalid_entries() {
  t_profile work
  t_active work
  mkdir -p -- "$T_HOME/.claude-profiles/.hidden" "$T_HOME/.claude-profiles/a b" \
    "$T_HOME/.claude-profiles/default"
  : > "$T_HOME/.claude-profiles/.active.Ab12Cd"
  : > "$T_HOME/.claude-profiles/plainfile"
  mkdir -p -- "$T/elsewhere"
  ln -s -- "$T/elsewhere" "$T_HOME/.claude-profiles/linked"
  ln -s -- "$T/nowhere" "$T_HOME/.claude-profiles/dangling"
  t_ccp ls
  assert_rc 0
  assert_eq "$T_OUT" "  default
  linked
* work" "ccp ls"
}

test_ls_shows_no_account_information() {
  t_profile work
  print -r -- '{"oauthAccount":{"emailAddress":"someone@example.com"}}' \
    > "$T_HOME/.claude-profiles/work/.claude.json"
  print -r -- '{"oauthAccount":{"emailAddress":"me@example.com"}}' > "$T_HOME/.claude.json"
  t_ccp ls
  assert_rc 0
  [[ $T_OUT$T_ERR != *@* ]] || fail "ccp ls 不应显示账号信息"
}

test_ls_warns_when_current_profile_is_missing() {
  t_profile work
  t_active gone
  t_ccp ls
  assert_eq "$T_OUT" "  default
  work" "ccp ls"
  assert_contains "$T_ERR" gone "stderr 应提到不存在的当前档案"
  assert_contains "$T_ERR" "ccp use default" "stderr 里应有修复建议"
}

test_ls_with_extra_argument_prints_usage() {
  t_ccp ls -l
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
}

# ---------- ccp current ----------

test_current_without_record_prints_default() {
  t_ccp current
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" default "当前档案"
}

test_current_prints_only_the_recorded_name() {
  t_profile work
  t_active work
  t_ccp current
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" work "当前档案"
}

test_current_record_default_prints_default() {
  t_active default
  t_ccp current
  assert_rc 0
  assert_eq "$T_OUT" default "当前档案"
}

test_current_missing_profile_prints_name_but_warns_and_fails() {
  t_active gone
  t_ccp current
  assert_rc_nonzero
  assert_eq "$T_OUT" gone "stdout 只有档案名"
  assert_contains "$T_ERR" "ccp use default" "stderr 里应有修复建议"
}

test_current_with_extra_argument_prints_usage() {
  t_ccp current extra
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
}

test_current_ignores_claude_profile() {
  t_profile work personal
  t_active work
  t_ccp CLAUDE_PROFILE=personal -- current
  assert_rc 0
  assert_eq "$T_OUT" work "终端覆盖不改变当前档案"
}

# ---------- ccp use ----------

ACTIVE() { print -r -- "$T_HOME/.claude-profiles/active" }

# 当前档案记录的原始字节（用 od 显示，能看出结尾换行）
active_bytes() { /usr/bin/od -An -c -- "$(ACTIVE)" }

test_use_writes_name_and_newline_and_new_shell_uses_it() {
  t_profile work
  t_ccp use work
  assert_rc 0
  assert_eq "$(active_bytes)" "$(print -r -- work | /usr/bin/od -An -c)" "记录内容应为 work 加换行"
  t_ccp current
  assert_eq "$T_OUT" work "ccp current"
  t_claude -- hi
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args hi
}

test_use_creates_profiles_root_when_missing() {
  t_ccp use default
  assert_rc 0
  assert_eq "$(< $(ACTIVE))" default "记录内容"
}

test_use_default_switches_back_to_default_profile() {
  t_profile work
  t_active work
  t_ccp use default
  assert_rc 0
  assert_eq "$(active_bytes)" "$(print -r -- default | /usr/bin/od -An -c)" "记录内容应为 default 加换行"
  t_claude
  assert_rc 0
  assert_claude_config_dir_unset
}

test_use_replaces_record_by_rename_and_leaves_no_temp_files() {
  t_profile work personal
  t_active work
  local before after
  before=$(/usr/bin/stat -f %i -- "$(ACTIVE)")
  t_ccp use personal
  assert_rc 0
  after=$(/usr/bin/stat -f %i -- "$(ACTIVE)")
  assert_ne "$after" "$before" "记录应被整体替换（重命名），而不是原地改写"
  assert_eq "$(< $(ACTIVE))" personal "记录内容"
  local -a left
  left=("$T_HOME/.claude-profiles"/*(DN:t))
  assert_eq "${(j: :)left}" "active personal work" "档案根目录里不应留下临时文件"
}

test_use_fails_without_touching_record_when_it_cannot_write() {
  t_profile work personal
  t_active work
  chmod 555 "$T_HOME/.claude-profiles"
  t_ccp use personal
  local rc=$T_RC
  chmod 755 "$T_HOME/.claude-profiles"
  T_RC=$rc
  assert_rc_nonzero
  assert_eq "$(< $(ACTIVE))" work "记录应保持不变"
}

assert_use_rejected() {  # 名字 错误信息里应有的内容
  t_profile work
  t_active work
  local before
  before=$(active_bytes)
  t_ccp use "$1"
  assert_rc_nonzero
  assert_contains "$T_ERR" "$2" "错误信息"
  assert_eq "$(active_bytes)" "$before" "记录应保持不变"
  [[ -z $T_OUT ]] || fail "stdout 应为空"
}

test_use_missing_profile_is_rejected() {
  assert_use_rejected gone "ccp add"
}

test_use_invalid_names_are_rejected_even_if_path_exists() {
  mkdir -p -- "$T_HOME/x" "$T_HOME/.claude-profiles/.hidden" "$T_HOME/.claude-profiles/a b"
  local n
  for n in ../x .hidden "a b" -work "" "wo/rk" "wörk"; do
    assert_use_rejected "$n" "不合规"
  done
}

test_use_reserved_name_active_is_rejected() {
  assert_use_rejected active "保留名"
}

test_use_rejects_a_file_that_looks_like_a_profile() {
  mkdir -p -- "$T_HOME/.claude-profiles"
  : > "$T_HOME/.claude-profiles/notadir"
  assert_use_rejected notadir "不存在"
}

test_use_accepts_profile_dir_reached_through_symlink() {
  # 与包装函数一致：档案目录本身是指向目录的软链接也算存在
  mkdir -p -- "$T/elsewhere"
  mkdir -p -- "$T_HOME/.claude-profiles"
  ln -s -- "$T/elsewhere" "$T_HOME/.claude-profiles/linked"
  t_ccp use linked
  assert_rc 0
  assert_eq "$(< $(ACTIVE))" linked "记录内容"
}

test_use_refuses_when_record_path_is_a_directory() {
  t_profile work
  mkdir -p -- "$T_HOME/.claude-profiles/active"
  t_ccp use work
  assert_rc_nonzero
  [[ -d "$T_HOME/.claude-profiles/active" ]] || fail "目录不应被替换"
  local -a inside
  inside=("$T_HOME/.claude-profiles/active"/*(DN))
  assert_eq "${#inside}" 0 "不应往目录里写东西"
}

test_use_without_name_or_with_extra_args_prints_usage() {
  t_profile work
  t_ccp use
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
  t_ccp use work extra
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
  [[ ! -e $(ACTIVE) ]] || fail "不应写入记录"
}

t_main "$@"
