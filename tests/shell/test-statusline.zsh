#!/bin/zsh -f
# 状态栏转发（token-usage ticket 04）：claude 包装函数用 --settings 把 statusLine.command 换成
# ccp statusline <档案名>；转发命令把 stdin 写进实时额度文件，再原样交给原本生效的状态栏命令。
source "${0:A:h}/lib.zsh"

# 实时额度文件和开关（与 shell/lib/profiles.zsh、Sources/Core/LiveQuotaFiles.swift 一致）
live_dir() { print -r -- "$T_HOME/.claude-profiles/.live-quota" }
live_file() { print -r -- "$(live_dir)/$1.json" }

# 包装函数最后一次加的覆盖里的状态栏命令（没有覆盖时失败）
override_command() {
  local -a reply
  claude_args
  [[ ${reply[1]-} == --settings ]] || fail "第 1 个参数应是 --settings，实际是 [${reply[1]-}]"
  print -rn -- "${reply[2]}" | /usr/bin/plutil -extract statusLine.command raw -o - - \
    || fail "--settings 的值里没有 statusLine.command：[${reply[2]}]"
}

# 以 Claude Code 的方式运行状态栏命令：/bin/sh -c，标准输入是文件 $1，工作目录是 $2（默认 $T）
run_statusline() {  # 命令 stdin文件 [工作目录]
  T_STDIN=$2
  t_run -- /bin/sh -c 'cd -- "$1" && shift && eval "$1"' _ "${3:-$T}" "$1"
}

# 写一份 Claude Code 交给状态栏的 JSON（不以换行结尾，便于比较字节）
status_json() {  # 输出文件 [project_dir]
  printf '%s' "{\"session_id\":\"s-1\",\"workspace\":{\"project_dir\":\"${2:-$T/proj}\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":12.5,\"resets_at\":1761400000}}}" > $1
}

# 在设置文件里配置一个状态栏命令：set_statusline 文件 命令
set_statusline() {
  mkdir -p -- ${1:h} || exit 1
  print -r -- "{\"statusLine\":{\"type\":\"command\",\"command\":\"$2\",\"padding\":2}}" > $1 || exit 1
}

# ---------- 包装函数加覆盖 ----------

test_default_profile_gets_statusline_override_before_user_args() {
  t_claude -- "a b" "" -p
  assert_rc 0
  assert_stderr_empty
  assert_claude_config_dir_unset
  local -a reply
  claude_args
  assert_eq "$(claude_field argc)" 5 "参数个数"
  assert_eq "${reply[1]}" --settings "第 1 个参数"
  assert_eq "$(print -rn -- "${reply[2]}" | /usr/bin/plutil -extract statusLine.type raw -o - -)" command "statusLine.type"
  assert_eq "${reply[3]}" "a b" "第 3 个参数"
  assert_eq "${reply[4]}" "" "第 4 个参数"
  assert_eq "${reply[5]}" -p "第 5 个参数"
  # 只覆盖 statusLine 的 type 和 command，其他字段（padding 等）留给用户自己的设置（深合并）
  local keys
  keys=$(print -rn -- "${reply[2]}" | /usr/bin/plutil -convert xml1 -o - - \
    | /usr/bin/grep -o '<key>[^<]*</key>' | /usr/bin/sort | /usr/bin/tr -d '\n')
  assert_eq "$keys" "<key>command</key><key>statusLine</key><key>type</key>" "覆盖里的键"
}

test_other_profile_gets_override_and_config_dir() {
  t_profile work
  t_active work
  t_claude -- --resume x
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  local -a reply
  claude_args
  assert_eq "$(claude_field argc)" 4 "参数个数"
  assert_eq "${reply[1]}" --settings "第 1 个参数"
  assert_eq "${reply[3]}" --resume "第 3 个参数"
  assert_eq "${reply[4]}" x "第 4 个参数"
  assert_contains "$(override_command)" "statusline work" "状态栏命令应带上档案名"
}

test_existing_config_dir_gets_no_override() {
  t_claude CLAUDE_CONFIG_DIR=/x/y -- a
  assert_rc 0
  assert_claude_args a
}

test_switch_off_means_no_override_on_both_paths() {
  mkdir -p -- "$(live_dir)" && : > "$(live_dir)/disabled"
  t_claude -- a
  assert_rc 0
  assert_claude_config_dir_unset
  assert_claude_args a
  t_profile work
  t_claude CLAUDE_PROFILE=work -- b
  assert_rc 0
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args b
}

test_user_supplied_settings_flag_means_no_override() {
  # 实测（Claude Code 2.1.310）：两个 --settings 只有最后一个生效，加了覆盖就会吃掉其中一个
  t_claude -- --settings /some/file.json -p q
  assert_rc 0
  assert_claude_args --settings /some/file.json -p q
  t_claude -- '--settings={"model":"x"}' q
  assert_rc 0
  assert_claude_args '--settings={"model":"x"}' q
}

test_override_command_survives_home_with_spaces_and_quotes() {
  # 路径里有空格和引号：命令先按 sh 引用，再按 JSON 转义，经 sh -c 运行后仍能找到 ccp
  local home="$T/it's \"home\""
  mkdir -p -- "$home" && cp -R -- $SHELL_SRC "$home/.cc-pilot" || exit 1
  set_statusline "$home/.claude/settings.json" 'printf forwarded'
  t_claude HOME=$home
  assert_rc 0
  local cmd
  cmd=$(override_command)
  status_json $T/in.json
  T_HOME=$home run_statusline "$cmd" $T/in.json
  assert_rc 0
  assert_eq "$T_OUT" forwarded "状态栏输出"
  [[ -f "$home/.claude-profiles/.live-quota/default.json" ]] || fail "应写出默认档案的实时额度文件"
}

# ---------- 端到端：包装函数加的命令 → 转发 ----------

test_end_to_end_forwards_to_profile_statusline_and_writes_live_file() {
  t_profile work
  t_active work
  set_statusline "$T_HOME/.claude-profiles/work/settings.json" 'cat > \"$HOME/seen\"; printf work-line'
  t_claude
  assert_rc 0
  local cmd
  cmd=$(override_command)
  status_json $T/in.json
  run_statusline "$cmd" $T/in.json
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" work-line "应原样输出原状态栏命令的输出"
  assert_eq "$(< "$T_HOME/seen")" "$(< $T/in.json)" "原状态栏命令应收到原样的 stdin"
  [[ -f $(live_file work) ]] || fail "应写出 work 的实时额度文件"
}

# ---------- ccp statusline：找出原本生效的状态栏并转发 ----------

# 以状态栏的方式运行 ccp statusline <档案名>，标准输入是文件 $2，工作目录是 $T
forward() {  # 档案名 stdin文件
  T_STDIN=$2
  t_ccp -- statusline $1
}

test_no_original_statusline_outputs_nothing_but_writes_live_file() {
  status_json $T/in.json
  forward default $T/in.json
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" "" "没有原状态栏时什么都不输出"
  local content
  content=$(< $(live_file default)) || fail "应写出 default.json"
  # 格式：{"profile":"<档案名>","received_at":<秒，三位小数>,"status":<原始 stdin JSON>}
  [[ $content == '{"profile":"default","received_at":'<->.[0-9][0-9][0-9]',"status":'"$(< $T/in.json)"'}' ]] \
    || fail "实时额度文件格式不对：[$content]"
  local at now=$(/bin/date +%s)
  at=$(/usr/bin/plutil -extract received_at raw -o - "$(live_file default)")
  (( ${at%.*} >= now - 60 && ${at%.*} <= now + 1 )) || fail "received_at 应是现在的时间戳，得到 $at"
  assert_eq "$(/usr/bin/plutil -extract status.rate_limits.five_hour.resets_at raw -o - "$(live_file default)")" \
    1761400000 "status 里应是原样的状态栏 JSON"
}

test_forwards_exact_stdin_and_stdout_of_profile_statusline() {
  t_profile work
  set_statusline "$T_HOME/.claude-profiles/work/settings.json" 'cat > ~/seen; printf \"line 1\\\\nline 2\\\\n\\\\n\"; exit 3'
  # 结尾带两个换行的 stdin 也要原样交过去
  printf '{"a":1,"workspace":{"project_dir":"%s"}}\n\n' "$T/proj" > $T/in.json
  forward work $T/in.json
  assert_rc 3
  assert_eq "$(/usr/bin/od -c < $T/out)" "$(printf 'line 1\nline 2\n\n' | /usr/bin/od -c)" "stdout 应逐字节相同"
  assert_eq "$(/usr/bin/od -c < "$T_HOME/seen")" "$(/usr/bin/od -c < $T/in.json)" "stdin 应逐字节相同"
  [[ -f $(live_file work) ]] || fail "应写出 work.json"
}

test_default_profile_reads_dot_claude_settings_not_other_profiles() {
  t_profile work
  set_statusline "$T_HOME/.claude/settings.json" 'printf from-default'
  set_statusline "$T_HOME/.claude-profiles/work/settings.json" 'printf from-work'
  status_json $T/in.json
  forward default $T/in.json
  assert_eq "$T_OUT" from-default "默认档案"
  forward work $T/in.json
  assert_eq "$T_OUT" from-work "work 档案"
}

test_project_settings_take_precedence_like_claude_code() {
  t_profile work
  set_statusline "$T_HOME/.claude-profiles/work/settings.json" 'printf user'
  status_json $T/in.json "$T/my proj"
  forward work $T/in.json
  assert_eq "$T_OUT" user "只有档案设置"
  set_statusline "$T/my proj/.claude/settings.json" 'printf project'
  forward work $T/in.json
  assert_eq "$T_OUT" project "项目设置优先于档案设置"
  set_statusline "$T/my proj/.claude/settings.local.json" 'printf local'
  forward work $T/in.json
  assert_eq "$T_OUT" local "项目本地设置最优先"
  # 没有 statusLine.command 的设置文件跳过，继续往下找
  print -r -- '{"model":"x"}' > "$T/my proj/.claude/settings.local.json"
  forward work $T/in.json
  assert_eq "$T_OUT" project "没配状态栏的文件应跳过"
}

test_statusline_runs_in_callers_directory_with_tilde_expanded() {
  set_statusline "$T_HOME/.claude/settings.json" 'printf %s \"$PWD\"; test -d ~/.cc-pilot && printf :home-ok'
  status_json $T/in.json
  mkdir -p -- $T/wd
  T_STDIN=$T/in.json
  t_run -- /bin/sh -c 'cd -- "$1" && exec "$HOME/.cc-pilot/bin/ccp" statusline default' _ $T/wd
  assert_eq "$T_OUT" "$T/wd:home-ok" "应在 Claude Code 给的工作目录里运行，~ 照常展开"
}

test_write_failure_is_silent_and_still_forwards() {
  set_statusline "$T_HOME/.claude/settings.json" 'printf still-here'
  status_json $T/in.json
  # 实时额度目录的位置被一个普通文件占了
  mkdir -p -- "$T_HOME/.claude-profiles" && : > "$(live_dir)" || exit 1
  forward default $T/in.json
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" still-here "写不了文件也要照常转发"
  # 目录在但不可写
  rm -f -- "$(live_dir)" && mkdir -p -- "$(live_dir)" && chmod 555 "$(live_dir)"
  forward default $T/in.json
  chmod 755 "$(live_dir)"
  assert_rc 0
  assert_stderr_empty
  assert_eq "$T_OUT" still-here "目录不可写也要照常转发"
}

test_atomic_write_leaves_no_temp_files_and_replaces_previous() {
  status_json $T/in.json
  forward default $T/in.json
  printf '{"session_id":"s-2"}' > $T/in2.json
  forward default $T/in2.json
  assert_eq "$(/usr/bin/plutil -extract status.session_id raw -o - "$(live_file default)")" s-2 "应替换为最新一份"
  local -a entries
  entries=("$(live_dir)"/*(DN:t))
  assert_eq "${entries[*]}" default.json "实时额度目录里只应有 default.json"
  entries=("$T_HOME/.claude-profiles"/*(DN:t))
  assert_eq "${entries[*]}" .live-quota "档案根目录里只应多出 .live-quota"
}

test_empty_or_non_json_stdin_writes_nothing() {
  : > $T/empty
  forward default $T/empty
  assert_rc 0
  [[ ! -e $(live_file default) ]] || fail "stdin 为空时不应写文件"
  print -r -- 'not json' > $T/bad
  forward default $T/bad
  [[ ! -e $(live_file default) ]] || fail "stdin 不是 JSON 对象时不应写文件"
}

test_invalid_profile_name_writes_nothing_and_outputs_nothing() {
  set_statusline "$T_HOME/.claude/settings.json" 'printf x'
  status_json $T/in.json
  local n
  for n in ../evil active "" ; do
    forward "$n" $T/in.json
    assert_rc 0
    assert_eq "$T_OUT" "" "名字 [$n] 不合规时不输出"
  done
  [[ ! -e "$T_HOME/.claude-profiles" ]] || fail "名字不合规时不应写任何文件"
}

test_statusline_pointing_back_at_forwarder_does_not_recurse() {
  set_statusline "$T_HOME/.claude/settings.json" '\"$HOME/.cc-pilot/bin/ccp\" statusline default; printf tail'
  status_json $T/in.json
  forward default $T/in.json
  assert_rc 0
  assert_eq "$T_OUT" tail "嵌套的转发命令应什么都不做"
}

t_main "$@"
