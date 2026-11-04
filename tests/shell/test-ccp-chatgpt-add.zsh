#!/bin/zsh -f
# ccp chatgpt add（别名 ccp codex add）：新建 ChatGPT 档案、布置共享资源、进入该档案的 codex login
# （chatgpt-profiles ticket 05；共享资源的做法见 ADR 0006，issue 01 实测 sqlite/ 不共享）。
source "${0:A:h}/lib.zsh"

# 作为目录共享的项（~/.codex 里没有时先创建）；AGENTS.md 只在 ~/.codex 里有时才建链接
typeset -ga SHARED_DIRS=(sessions archived_sessions thread-writer-locks .tmp skills plugins rules)

# 列出目录里的全部项（含隐藏项），按名字排序，每行一项
dir_entries() {
  local -a e
  e=("$1"/*(DN:t))
  print -rl -- ${(o)e}
}

# 新档案 config.toml 的第一行（sqlite_home 指向默认档案的绝对路径）
sqlite_line() {
  print -r -- "sqlite_home = \"$T_HOME/.codex\""
}

# ---------- 新建并登录 ----------

test_creates_profile_dir_and_runs_codex_login_in_it() {
  t_codex_default
  t_ccp chatgpt add work
  assert_rc 0
  [[ -d $T_HOME/.codex-profiles/work && ! -L $T_HOME/.codex-profiles/work ]] || fail "应创建档案目录"
  assert_codex_calls 1
  assert_codex_home "$T_HOME/.codex-profiles/work"
  assert_codex_args login
}

test_codex_alias_also_adds() {
  t_codex_default
  t_ccp codex add work
  assert_rc 0
  [[ -d $T_HOME/.codex-profiles/work ]] || fail "ccp codex add 应创建档案目录"
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_login_ignores_codex_profile_and_codex_home_in_environment() {
  t_codex_default
  t_codex_profile other
  t_ccp CODEX_PROFILE=other CODEX_HOME="$T_HOME/.codex-profiles/other" -- chatgpt add work
  assert_rc 0
  assert_codex_calls 1
  assert_codex_home "$T_HOME/.codex-profiles/work"
}

test_successful_login_leaves_auth_json_in_new_profile_only() {
  t_codex_default
  t_ccp chatgpt add work
  assert_rc 0
  [[ -f $T_HOME/.codex-profiles/work/auth.json ]] || fail "codex login 应在新档案里写 auth.json"
  [[ ! -e $T_HOME/.codex/auth.json ]] || fail "不应在默认档案里登录"
}

test_login_failure_keeps_profile_and_explains_how_to_sign_in_later() {
  t_codex_default
  t_ccp FAKE_CODEX_EXIT=3 -- chatgpt add work
  assert_rc 3
  [[ -L $T_HOME/.codex-profiles/work/sessions ]] || fail "登录失败时档案应保留"
  [[ -f $T_HOME/.codex-profiles/work/config.toml ]] || fail "登录失败时 config.toml 应保留"
  assert_contains "$T_ERR" "已保留" "应说明档案已保留"
  assert_contains "$T_ERR" "codex login" "应提示之后怎么登录"
  assert_contains "$T_ERR" "CODEX_HOME=" "提示的命令应指定这个档案"
}

test_suggested_login_command_signs_in_to_the_new_profile() {
  # 照着提示执行，登录的是新档案（路径里带空格，提示里的命令要正确引用）
  t_codex_default
  t_ccp FAKE_CODEX_EXIT=1 -- chatgpt add work
  assert_rc 1
  local cmd=${${(f)T_ERR}[-1]}
  cmd=${cmd##[[:space:]]#}
  t_run -- /bin/zsh -f -c "$cmd"
  assert_rc 0
  [[ -f $T_HOME/.codex-profiles/work/auth.json ]] || fail "照提示登录后新档案应有 auth.json"
  [[ ! -e $T_HOME/.codex/auth.json ]] || fail "不应登录到默认档案"
}

test_login_exiting_zero_without_auth_json_counts_as_not_signed_in() {
  t_codex_default
  t_ccp FAKE_CODEX_HOOK='rm -f -- "$CODEX_HOME/auth.json"' -- chatgpt add work
  assert_rc_nonzero
  [[ -d $T_HOME/.codex-profiles/work ]] || fail "档案应保留"
  assert_contains "$T_ERR" "codex login" "应提示之后怎么登录"
}

# ---------- 共享资源 ----------

test_links_shared_dirs_to_default_profile_creating_missing_ones() {
  # 默认档案里只有一部分共享目录：其余的先在 ~/.codex 里创建
  mkdir -p -- "$T_HOME/.codex/sessions" "$T_HOME/.codex/skills"
  print -r -- old > "$T_HOME/.codex/sessions/keep" || exit 1
  t_ccp chatgpt add work
  assert_rc 0
  local dir="$T_HOME/.codex-profiles/work" item
  for item in $SHARED_DIRS; do
    [[ -L $dir/$item ]] || fail "$item 应当是软链接"
    assert_eq "$(/usr/bin/readlink -- "$dir/$item")" "$T_HOME/.codex/$item" "$item 的指向"
    [[ -d $T_HOME/.codex/$item && ! -L $T_HOME/.codex/$item ]] || fail "默认档案里应有目录 $item"
  done
  assert_eq "$(< "$T_HOME/.codex/sessions/keep")" old "默认档案已有的内容不变"
}

test_creates_default_profile_dirs_when_codex_dir_is_missing() {
  t_ccp chatgpt add work
  assert_rc 0
  local item
  for item in $SHARED_DIRS; do
    [[ -d $T_HOME/.codex/$item ]] || fail "应在 ~/.codex 里创建 $item"
  done
}

test_links_agents_md_only_when_default_profile_has_it() {
  t_codex_default
  t_ccp chatgpt add without
  assert_rc 0
  [[ ! -e $T_HOME/.codex-profiles/without/AGENTS.md && ! -L $T_HOME/.codex-profiles/without/AGENTS.md ]] ||
    fail "默认档案没有 AGENTS.md 时不应建链接"
  [[ ! -e $T_HOME/.codex/AGENTS.md ]] || fail "不应在默认档案里创建 AGENTS.md"

  print -r -- "# 指令" > "$T_HOME/.codex/AGENTS.md"
  t_ccp chatgpt add with
  assert_rc 0
  [[ -L $T_HOME/.codex-profiles/with/AGENTS.md ]] || fail "AGENTS.md 应当是软链接"
  assert_eq "$(/usr/bin/readlink -- "$T_HOME/.codex-profiles/with/AGENTS.md")" "$T_HOME/.codex/AGENTS.md" \
    "AGENTS.md 的指向"
}

test_new_profile_has_only_config_shared_links_and_login() {
  # 默认档案里有每个档案一份的文件和桌面 App 的库：都不应出现在新档案里
  t_codex_default
  mkdir -p -- "$T_HOME/.codex/sqlite" "$T_HOME/.codex/sessions"
  print -r -- '{}' > "$T_HOME/.codex/auth.json"
  print -r -- id > "$T_HOME/.codex/installation_id"
  print -r -- '{}' > "$T_HOME/.codex/.codex-global-state.json"
  print -r -- '{}' > "$T_HOME/.codex/history.jsonl"
  print -r -- x > "$T_HOME/.codex/state_5.sqlite"
  print -r -- "# 指令" > "$T_HOME/.codex/AGENTS.md"
  print -r -- 'model = "gpt-5"' > "$T_HOME/.codex/config.toml"
  t_ccp FAKE_CODEX_EXIT=1 -- chatgpt add work
  assert_eq "$(dir_entries "$T_HOME/.codex-profiles/work")" \
    "$(print -rl -- config.toml AGENTS.md $SHARED_DIRS | sort)" "新档案目录的内容（登录前）"
}

test_shared_sessions_written_in_new_profile_land_in_default_profile() {
  t_codex_default
  t_ccp chatgpt add work
  assert_rc 0
  print -r -- '{}' > "$T_HOME/.codex-profiles/work/sessions/rollout.jsonl"
  [[ -f $T_HOME/.codex/sessions/rollout.jsonl ]] || fail "写进新档案 sessions/ 的会话应出现在 ~/.codex/sessions/"
}

test_paths_have_no_double_or_trailing_slash_when_home_ends_with_slash() {
  t_codex_default
  t_ccp HOME="$T_HOME/" -- chatgpt add work
  assert_rc 0
  assert_codex_home "$T_HOME/.codex-profiles/work"
  assert_eq "$(/usr/bin/readlink -- "$T_HOME/.codex-profiles/work/skills")" "$T_HOME/.codex/skills" "软链接的指向"
  assert_eq "$(head -n 1 -- "$T_HOME/.codex-profiles/work/config.toml")" "$(sqlite_line)" "sqlite_home"
}

# ---------- config.toml ----------

test_config_toml_is_created_with_sqlite_home_when_default_has_none() {
  t_codex_default
  t_ccp chatgpt add work
  assert_rc 0
  assert_stderr_empty
  local out="$T_HOME/.codex-profiles/work/config.toml"
  [[ -f $out && ! -L $out ]] || fail "新档案应有自己的 config.toml（普通文件）"
  assert_eq "$(< $out)" "$(sqlite_line)" "新档案的 config.toml"
  [[ ! -e $T_HOME/.codex/config.toml ]] || fail "不应在默认档案里创建 config.toml"
}

test_config_toml_copies_default_verbatim_with_sqlite_home_first() {
  t_codex_default
  local content='# 我的设置
model = "gpt-5-codex"
model_reasoning_effort = "high"

[projects."/Users/张三/a b"]
trust_level = "trusted"

[mcp_servers.docs]
command = "npx"
args = ["-y", "docs"]'
  print -r -- "$content" > "$T_HOME/.codex/config.toml"
  t_ccp chatgpt add work
  assert_rc 0
  assert_eq "$(< "$T_HOME/.codex-profiles/work/config.toml")" "$(sqlite_line)
$content" "新档案的 config.toml"
  assert_eq "$(< "$T_HOME/.codex/config.toml")" "$content" "默认档案的 config.toml 不变"
}

test_config_toml_overrides_existing_top_level_sqlite_home() {
  t_codex_default
  print -r -- 'model = "gpt-5"
  sqlite_home = "/elsewhere"   # 旧值
"sqlite_home" = "/quoted"

[tools]
sqlite_home = "/not-top-level"' > "$T_HOME/.codex/config.toml"
  t_ccp chatgpt add work
  assert_rc 0
  assert_eq "$(< "$T_HOME/.codex-profiles/work/config.toml")" "$(sqlite_line)
model = \"gpt-5\"

[tools]
sqlite_home = \"/not-top-level\"" "顶层的 sqlite_home 被覆盖，表里的同名键不动"
}

test_config_toml_copies_target_when_default_is_a_symlink() {
  t_codex_default
  mkdir -p -- "$T_HOME/dotfiles"
  print -r -- 'model = "o3"' > "$T_HOME/dotfiles/config.toml"
  ln -s -- "$T_HOME/dotfiles/config.toml" "$T_HOME/.codex/config.toml"
  t_ccp chatgpt add work
  assert_rc 0
  local out="$T_HOME/.codex-profiles/work/config.toml"
  [[ -f $out && ! -L $out ]] || fail "新档案的 config.toml 应是普通文件"
  assert_eq "$(< $out)" "$(sqlite_line)
model = \"o3\"" "新档案的 config.toml"
}

test_config_toml_changes_do_not_propagate_between_profiles() {
  t_codex_default
  print -r -- 'model = "a"' > "$T_HOME/.codex/config.toml"
  t_ccp chatgpt add work
  assert_rc 0
  print -r -- 'model = "b"' >> "$T_HOME/.codex-profiles/work/config.toml"
  assert_eq "$(< "$T_HOME/.codex/config.toml")" 'model = "a"' "改新档案不应影响默认档案"
}

test_unreadable_default_config_toml_still_creates_profile_with_hint() {
  t_codex_default
  print -r -- 'model = "a"' > "$T_HOME/.codex/config.toml"
  chmod 000 "$T_HOME/.codex/config.toml"
  t_ccp chatgpt add work
  chmod 644 "$T_HOME/.codex/config.toml"
  assert_rc 0
  assert_contains "$T_ERR" "config.toml" "应提示没有复制设置"
  assert_eq "$(< "$T_HOME/.codex-profiles/work/config.toml")" "$(sqlite_line)" "新档案的 config.toml 只有 sqlite_home"
  [[ ! -e $T_HOME/.codex-profiles/work/config.toml.ccp-tmp ]] || fail "不应留下临时文件"
  assert_codex_calls 1
}

test_sqlite_home_escapes_quotes_and_backslashes_in_home() {
  local home="$T/we\"ird\\home"
  mkdir -p -- "$home/.codex" || exit 1
  t_ccp HOME="$home" -- chatgpt add work
  assert_rc 0
  assert_eq "$(< "$home/.codex-profiles/work/config.toml")" "sqlite_home = \"$T/we\\\"ird\\\\home/.codex\"" \
    "TOML 基本字符串里的引号和反斜杠应转义"
}

# ---------- 拒绝的情况：报错、非零退出、不修改任何文件 ----------

# 输出临时 HOME 下（不含安装目录 .cc-pilot）每一项的路径、类型、大小、链接目标和修改时间
home_snapshot() {
  /usr/bin/find "$T_HOME" -path "$T_HOME/.cc-pilot" -prune -o -print0 |
    /usr/bin/xargs -0 /usr/bin/stat -f '%N|%HT|%z|%Y|%m' | /usr/bin/sort
}

assert_rejected_without_changes() {  # 说明 ccp-chatgpt-add 的参数...
  local what=$1 before; shift
  before=$(home_snapshot)
  t_ccp -- chatgpt add "$@"
  (( T_RC != 0 )) || fail "$what: 应以非零状态退出"
  [[ -n $T_ERR ]] || fail "$what: 应在 stderr 报错"
  assert_eq "$(home_snapshot)" "$before" "$what: 不应修改任何文件"
  assert_codex_calls 0
}

test_rejects_missing_or_extra_arguments() {
  t_codex_default
  assert_rejected_without_changes "没有名字"
  assert_rejected_without_changes "多余的参数" work extra
}

test_rejects_invalid_names_even_without_profiles_root() {
  t_codex_default
  local n
  for n in "" ../x .hidden -x "a b" "a/b" "名字" "x*"; do
    assert_rejected_without_changes "不合规的名字 [$n]" "$n"
  done
  [[ ! -e $T_HOME/.codex-profiles ]] || fail "不应创建 ~/.codex-profiles"
}

test_rejects_reserved_names() {
  t_codex_default
  assert_rejected_without_changes "保留名 default" default
  assert_rejected_without_changes "保留名 active（没有当前档案记录时）" active
  t_codex_profile work
  t_codex_active work
  assert_rejected_without_changes "保留名 active（有当前档案记录时）" active
}

test_rejects_existing_profile() {
  t_codex_default
  t_codex_profile work
  print -r -- '{}' > "$T_HOME/.codex-profiles/work/auth.json"
  assert_rejected_without_changes "已存在的档案" work
  assert_contains "$T_ERR" "已存在" "应报告档案已存在"
}

test_rejects_name_whose_path_is_taken_by_file_or_dangling_link() {
  t_codex_default
  mkdir -p -- "$T_HOME/.codex-profiles"
  print -r -- x > "$T_HOME/.codex-profiles/afile"
  ln -s -- "$T_HOME/nowhere" "$T_HOME/.codex-profiles/alink"
  assert_rejected_without_changes "同名的普通文件" afile
  assert_contains "$T_ERR" "已存在" "应报告名字已被占用"
  assert_rejected_without_changes "同名的悬空软链接" alink
  assert_contains "$T_ERR" "已存在" "应报告名字已被占用"
}

test_does_not_touch_claude_profiles() {
  t_codex_default
  t_profile work
  t_ccp chatgpt add work
  assert_rc 0
  assert_eq "$(dir_entries "$T_HOME/.claude-profiles/work")" "" "Claude 的同名档案不受影响"
}

# ---------- 当前档案 ----------

test_add_does_not_change_or_create_active_record() {
  t_codex_default
  t_ccp chatgpt add work
  assert_rc 0
  [[ ! -e $T_HOME/.codex-profiles/active ]] || fail "不应创建当前档案记录"
  t_codex_active work
  t_ccp chatgpt add other
  assert_rc 0
  assert_eq "$(< "$T_HOME/.codex-profiles/active")" work "当前档案记录"
}

test_new_profile_is_listed_by_ls() {
  t_codex_default
  t_ccp chatgpt add work
  t_ccp chatgpt ls
  assert_rc 0
  assert_eq "$T_OUT" "* default
  work" "ccp chatgpt ls"
}
t_main "$@"
