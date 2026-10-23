#!/bin/zsh -f
# ccp add：新建档案、共享资源的软链接、.claude.json 的初始值、进入新档案的 Claude Code（ticket 03）
source "${0:A:h}/lib.zsh"

typeset -ga SHARED_ITEMS=(settings.json CLAUDE.md skills agents commands plugins projects)

# 输出一个 JSON 文件的紧凑形式（保持键的顺序），用来和手写的期望值比较。只用 macOS 自带的 JXA。
json_canon() {
  /usr/bin/osascript -l JavaScript - "$1" <<'EOF'
ObjC.import('Foundation');
function run(argv) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (s.isNil()) throw new Error('cannot read ' + argv[0]);
  return JSON.stringify(JSON.parse(s.js));
}
EOF
}

# 列出目录里的全部项（含隐藏项），按名字排序，每行一项
dir_entries() {
  local -a e
  e=("$1"/*(DN:t))
  print -rl -- ${(o)e}
}

# 在临时 HOME 里写默认档案的 .claude.json
default_claude_json() {
  print -r -- "$1" > "$T_HOME/.claude.json" || exit 1
}

# ---------- 共享资源 ----------

test_new_profile_links_every_shared_item_to_default_profile() {
  # 默认档案里只有一部分共享项：不存在的（例如 CLAUDE.md、commands/）也照样建软链接
  mkdir -p -- "$T_HOME/.claude/skills" "$T_HOME/.claude/agents" "$T_HOME/.claude/plugins" \
    "$T_HOME/.claude/projects"
  print -r -- '{}' > "$T_HOME/.claude/settings.json"
  t_ccp -- add work
  assert_rc 0
  local dir="$T_HOME/.claude-profiles/work" item
  for item in $SHARED_ITEMS; do
    [[ -L $dir/$item ]] || fail "$item 应当是软链接"
    assert_eq "$(/usr/bin/readlink -- "$dir/$item")" "$T_HOME/.claude/$item" "$item 的指向"
  done
}

test_new_profile_has_only_shared_links_and_its_own_claude_json() {
  # 默认档案里有独有文件和运行时目录：都不应出现在新档案里
  mkdir -p -- "$T_HOME/.claude/"{skills,sessions,shell-snapshots,cache,todos,statsig}
  print -r -- '{}' > "$T_HOME/.claude/settings.json"
  print -r -- '{"display":"hi"}' > "$T_HOME/.claude/history.jsonl"
  default_claude_json '{"projects":{}}'
  t_ccp -- add work
  assert_rc 0
  assert_eq "$(dir_entries "$T_HOME/.claude-profiles/work")" \
    "$(print -rl -- .claude.json $SHARED_ITEMS | sort)" "新档案目录的内容"
}

# ---------- .claude.json 的初始值 ----------

test_new_claude_json_copies_only_mcp_servers_and_projects_verbatim() {
  local nfd=$(printf '/Users/Jose\xcc\x81/w')
  default_claude_json '{
  "numStartups": 3,
  "oauthAccount": {"emailAddress": "a@example.com", "accountUuid": "u-1"},
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.309",
  "mcpServers": {"srv.one": {"command": "x", "env": null, "args": ["-y", "a.b"]}},
  "projects": {
    "/Users/张三/a.b": {"hasTrustDialogAccepted": true, "lastCost": null, "allowedTools": []},
    "'$nfd'": {"mcpServers": {}}
  },
  "userID": "abc"
}'
  t_ccp -- add work
  assert_rc 0
  local out="$T_HOME/.claude-profiles/work/.claude.json"
  [[ -f $out && ! -L $out ]] || fail "新档案应有自己的 .claude.json（普通文件）"
  assert_eq "$(json_canon $out)" \
    '{"mcpServers":{"srv.one":{"command":"x","env":null,"args":["-y","a.b"]}},"projects":{"/Users/张三/a.b":{"hasTrustDialogAccepted":true,"lastCost":null,"allowedTools":[]},"'$nfd'":{"mcpServers":{}}}}' \
    "新档案的 .claude.json"
  assert_contains "$(< $out)" "张三" "非 ASCII 字符应按 UTF-8 原样写入"
}

test_new_claude_json_omits_fields_missing_from_default_profile() {
  default_claude_json '{"projects":{"/p":{"x":null}},"oauthAccount":{"accountUuid":"u"}}'
  t_ccp -- add work
  assert_rc 0
  assert_eq "$(json_canon "$T_HOME/.claude-profiles/work/.claude.json")" \
    '{"projects":{"/p":{"x":null}}}' "默认档案没有 mcpServers 时不写这个字段"
}

test_new_claude_json_keeps_top_level_null_field() {
  default_claude_json '{"mcpServers":null,"hasCompletedOnboarding":true}'
  t_ccp -- add work
  assert_rc 0
  assert_eq "$(json_canon "$T_HOME/.claude-profiles/work/.claude.json")" \
    '{"mcpServers":null}' "null 值保留"
}

assert_created_without_initial_values() {  # 档案名
  local dir="$T_HOME/.claude-profiles/$1"
  assert_rc 0
  [[ -d $dir ]] || fail "仍应创建档案目录"
  [[ -L $dir/settings.json ]] || fail "仍应建立共享资源的软链接"
  [[ ! -e $dir/.claude.json && ! -L $dir/.claude.json ]] || fail "不应写入 .claude.json"
  assert_eq "$(dir_entries $dir)" "$(print -rl -- $SHARED_ITEMS | sort)" "档案目录里不应留下临时文件"
  assert_contains "$T_ERR" ".claude.json" "应提示没有复制初始值"
  assert_claude_calls 1
}

test_missing_default_claude_json_still_creates_profile_with_hint() {
  t_ccp -- add work
  assert_created_without_initial_values work
}

test_unparseable_default_claude_json_still_creates_profile_with_hint() {
  default_claude_json '{"projects": {'
  t_ccp -- add work
  assert_created_without_initial_values work
  assert_eq "$(< "$T_HOME/.claude.json")" '{"projects": {' "不应修改默认档案的 .claude.json"
}

test_non_object_default_claude_json_still_creates_profile_with_hint() {
  default_claude_json '[{"projects":{}}]'
  t_ccp -- add work
  assert_created_without_initial_values work
}

# ---------- 进入新档案的 Claude Code ----------

test_launches_claude_in_new_profile_with_absolute_config_dir() {
  t_ccp -- add work
  assert_rc 0
  assert_claude_calls 1
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args
}

test_launch_ignores_claude_profile_pointing_at_another_profile() {
  t_profile other
  t_ccp CLAUDE_PROFILE=other -- add work
  assert_rc 0
  assert_claude_calls 1
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
}

test_launch_overrides_config_dir_already_in_environment() {
  t_profile other
  t_ccp CLAUDE_CONFIG_DIR="$T_HOME/.claude-profiles/other" -- add work
  assert_rc 0
  assert_claude_calls 1
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
}

test_paths_have_no_double_or_trailing_slash_when_home_ends_with_slash() {
  t_ccp HOME="$T_HOME/" -- add work
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_eq "$(/usr/bin/readlink -- "$T_HOME/.claude-profiles/work/skills")" \
    "$T_HOME/.claude/skills" "软链接的指向"
}

test_profile_is_kept_when_claude_exits_with_error() {
  t_ccp FAKE_CLAUDE_EXIT=3 -- add work
  assert_rc 3
  [[ -L $T_HOME/.claude-profiles/work/settings.json ]] || fail "档案应保留"
}

# ---------- 拒绝的情况：报错、非零退出、不修改任何文件 ----------

# 输出临时 HOME 下（不含安装目录 .cc-pilot）每一项的路径、类型、大小、链接目标和修改时间
home_snapshot() {
  /usr/bin/find "$T_HOME" -path "$T_HOME/.cc-pilot" -prune -o -print0 |
    /usr/bin/xargs -0 /usr/bin/stat -f '%N|%HT|%z|%Y|%m' | /usr/bin/sort
}

assert_rejected_without_changes() {  # 说明 ccp-add 的参数...
  local what=$1 before; shift
  before=$(home_snapshot)
  t_ccp -- add "$@"
  (( T_RC != 0 )) || fail "$what: 应以非零状态退出"
  [[ -n $T_ERR ]] || fail "$what: 应在 stderr 报错"
  assert_eq "$(home_snapshot)" "$before" "$what: 不应修改任何文件"
  assert_claude_calls 0
}

prepare_typical_home() {
  mkdir -p -- "$T_HOME/.claude/skills"
  print -r -- '{}' > "$T_HOME/.claude/settings.json"
  default_claude_json '{"projects":{}}'
}

test_rejects_missing_or_extra_arguments() {
  prepare_typical_home
  assert_rejected_without_changes "没有名字"
  assert_rejected_without_changes "多余的参数" work extra
}

test_rejects_invalid_names_even_without_profiles_root() {
  prepare_typical_home
  local n
  for n in "" ../x .hidden -x "a b" "a/b" "名字" "x*"; do
    assert_rejected_without_changes "不合规的名字 [$n]" "$n"
  done
  [[ ! -e $T_HOME/.claude-profiles ]] || fail "不应创建 ~/.claude-profiles"
}

test_rejects_reserved_names() {
  prepare_typical_home
  assert_rejected_without_changes "保留名 default" default
  assert_rejected_without_changes "保留名 active（没有当前档案记录时）" active
  t_active work
  t_profile work
  assert_rejected_without_changes "保留名 active（有当前档案记录时）" active
}

test_rejects_existing_profile() {
  prepare_typical_home
  t_profile work
  print -r -- '{"oauthAccount":{}}' > "$T_HOME/.claude-profiles/work/.claude.json"
  assert_rejected_without_changes "已存在的档案" work
  assert_contains "$T_ERR" "已存在" "应报告档案已存在"
}

test_rejects_name_whose_path_is_taken_by_file_or_dangling_link() {
  prepare_typical_home
  mkdir -p -- "$T_HOME/.claude-profiles"
  print -r -- x > "$T_HOME/.claude-profiles/afile"
  ln -s -- "$T_HOME/nowhere" "$T_HOME/.claude-profiles/alink"
  assert_rejected_without_changes "同名的普通文件" afile
  assert_contains "$T_ERR" "已存在" "应报告名字已被占用"
  assert_rejected_without_changes "同名的悬空软链接" alink
  assert_contains "$T_ERR" "已存在" "应报告名字已被占用"
}

# ---------- 当前档案 ----------

test_add_does_not_change_active_profile() {
  t_profile other
  t_active other
  t_ccp -- add work
  assert_rc 0
  assert_eq "$(< "$T_HOME/.claude-profiles/active")" other "当前档案记录"
}

test_add_does_not_create_active_record() {
  t_ccp -- add work
  assert_rc 0
  [[ ! -e $T_HOME/.claude-profiles/active ]] || fail "不应创建当前档案记录"
}

t_main "$@"
