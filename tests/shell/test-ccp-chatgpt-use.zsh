#!/bin/zsh -f
# ccp chatgpt use <名字>（别名 ccp codex use）：切换 ChatGPT 当前档案（chatgpt-profiles ticket 04，ADR 0005）。
# 切换 = 写当前档案记录 ~/.codex-profiles/active + launchctl setenv/unsetenv CODEX_HOME
#        + ChatGPT 桌面 App（com.openai.codex）运行时按选择退出并重新打开。
# launchd 环境、桌面 App 都是假的（tests/fakes/launchctl、osascript、open）。
source "${0:A:h}/lib.zsh"

ACTIVE() { print -r -- "$T_HOME/.codex-profiles/active" }
active_bytes() { od -An -c -- "$(ACTIVE)" | tr -d ' \n' }  # 例如 work\n

# ---------- 当前档案记录与 launchd ----------

test_use_writes_record_and_sets_codex_home_in_launchd() {
  t_codex_default
  t_codex_profile work
  t_ccp chatgpt use work
  assert_rc 0
  assert_stderr_empty
  assert_eq "$(< $(ACTIVE))" work "当前档案记录"
  assert_eq "$(active_bytes)" 'work\n' "记录是名字加一个换行"
  assert_eq "$(launchd_env CODEX_HOME)" "$T_HOME/.codex-profiles/work" "launchd 里的 CODEX_HOME"
}

test_use_default_writes_default_and_unsets_codex_home() {
  t_codex_default
  t_codex_profile work
  t_codex_active work
  t_launchd_env CODEX_HOME "$T_HOME/.codex-profiles/work"
  t_ccp chatgpt use default
  assert_rc 0
  assert_stderr_empty
  assert_eq "$(active_bytes)" 'default\n' "切回默认档案也写入 default"
  assert_eq "$(launchd_env CODEX_HOME)" "<unset>" "launchd 里的 CODEX_HOME 应被去掉"
}

test_codex_is_an_alias_and_home_with_trailing_slash_is_not_doubled() {
  t_codex_profile work
  t_ccp HOME="$T_HOME/" codex use work
  assert_rc 0
  assert_eq "$(< $(ACTIVE))" work "当前档案记录"
  assert_eq "$(launchd_env CODEX_HOME)" "$T_HOME/.codex-profiles/work" "CODEX_HOME 是不带重复斜杠的绝对路径"
}

test_use_creates_profiles_root_and_says_what_follows() {
  t_codex_default
  t_ccp chatgpt use default
  assert_rc 0
  assert_eq "$(active_bytes)" 'default\n' "根目录不存在时创建并写入"
  assert_contains "$T_OUT" "codex" "说明之后的 codex 会使用它"
}

test_use_is_idempotent() {
  t_codex_profile work
  t_ccp chatgpt use work
  t_ccp chatgpt use work
  assert_rc 0
  assert_stderr_empty
  assert_eq "$(< $(ACTIVE))" work "当前档案记录"
  assert_eq "$(launchd_env CODEX_HOME)" "$T_HOME/.codex-profiles/work" "launchd 里的 CODEX_HOME"
}

test_launchctl_failure_is_reported() {
  t_codex_profile work
  mkdir -p -- $T_LAUNCHD && print -r -- 1 > $T_LAUNCHD/exit
  t_chatgpt_app running
  t_ccp chatgpt use work --restart
  assert_eq "$T_RC" 1 "launchctl 失败时退出码"
  assert_contains "$T_ERR" launchctl "错误信息里说明是 launchctl"
  assert_eq "$(chatgpt_app_calls)" "" "launchctl 失败时不动桌面 App"
}

# ---------- 拒绝 ----------

# 期望被拒：退出码 $1，错误信息含 $2，之后是 ccp chatgpt use 的参数；记录、launchd、桌面 App 都不变
assert_use_rejected() {
  local rc=$1 fragment=$2; shift 2
  t_codex_profile work
  t_codex_active work
  t_launchd_env CODEX_HOME "$T_HOME/.codex-profiles/work"
  t_chatgpt_app running
  t_ccp chatgpt use "$@"
  assert_eq "$T_RC" $rc "退出码（参数：$*）"
  assert_contains "$T_ERR" "$fragment" "错误信息（参数：$*）"
  assert_eq "$T_OUT" "" "被拒时 stdout 应为空"
  assert_eq "$(active_bytes)" 'work\n' "记录不变"
  assert_eq "$(launchctl_calls)" 0 "不应调用 launchctl"
  assert_eq "$(launchd_env CODEX_HOME)" "$T_HOME/.codex-profiles/work" "launchd 不变"
  assert_eq "$(chatgpt_app_calls)" "" "不应查询或退出桌面 App"
}

test_rejects_missing_profile_with_hint() { assert_use_rejected 1 "ccp chatgpt add gone" gone }
test_rejects_name_differing_in_case() { assert_use_rejected 1 '"work"' Work }
test_rejects_reserved_and_malformed_names() {
  assert_use_rejected 1 active active
  assert_use_rejected 1 "档案名" "../x"
  assert_use_rejected 1 "档案名" ""
}
test_rejects_claude_only_profile() {
  t_profile claudeonly
  assert_use_rejected 1 claudeonly claudeonly
}
test_rejects_bad_usage() {
  assert_use_rejected 2 "用法" 
  assert_use_rejected 2 "只需要一个" work default
  assert_use_rejected 2 "只能选一个" work --restart --no-restart
  assert_use_rejected 2 "未知选项" work --force
}

test_record_location_is_directory_is_rejected() {
  t_codex_profile work
  mkdir -p -- "$(ACTIVE)"
  t_ccp chatgpt use work
  assert_eq "$T_RC" 1 "退出码"
  [[ -d $(ACTIVE) ]] || fail "记录位置的目录应保持不变"
  assert_eq "$(launchctl_calls)" 0 "不应调用 launchctl"
}

# ---------- 桌面 App ----------

test_app_not_running_is_left_alone_without_asking() {
  t_codex_profile work
  t_stdin y
  t_ccp chatgpt use work
  assert_rc 0
  assert_stderr_empty
  [[ $T_OUT != *"[y/N]"* ]] || fail "桌面 App 没在运行时不应询问"
  assert_eq "$(chatgpt_app_calls)" "osascript application id \"com.openai.codex\" is running" "只查询是否在运行"
}

test_running_app_asks_and_yes_quits_then_reopens_with_new_home() {
  t_codex_profile work
  t_chatgpt_app running
  t_stdin y
  t_ccp chatgpt use work
  assert_rc 0
  assert_stderr_empty
  assert_contains "$T_OUT" "[y/N]" "应询问是否重启"
  assert_contains "$T_OUT" "重启 ChatGPT" "询问的内容"
  chatgpt_app_running || fail "重启后桌面 App 应在运行"
  assert_eq "$(< $T_CHATGPT_APP/running)" "$T_HOME/.codex-profiles/work" "重新打开的桌面 App 从 launchd 拿到新档案"
  local calls=$(chatgpt_app_calls)
  assert_contains "$calls" 'osascript tell application id "com.openai.codex" to quit' "应请桌面 App 退出"
  assert_eq "${${(f)calls}[-1]}" "open com.openai.codex" "最后用 open -b 重新打开"
}

test_running_app_answer_yes_is_case_insensitive() {
  t_codex_profile work
  t_chatgpt_app running
  t_stdin YES
  t_ccp chatgpt use work
  assert_rc 0
  assert_contains "$(chatgpt_app_calls)" "open com.openai.codex" "YES 也算同意"
}

test_running_app_declined_switches_without_restart() {
  local answer
  for answer in n "" "yes please"; do
    rm -rf -- $T_CHATGPT_APP $T_LAUNCHD
    t_codex_profile work
    t_chatgpt_app running
    t_stdin "$answer"
    t_ccp chatgpt use work
    assert_rc 0
    assert_stderr_empty
    assert_contains "$T_OUT" "下次打开" "说明下次打开时生效（回答：$answer）"
    assert_eq "$(< $(ACTIVE))" work "档案照样切换（回答：$answer）"
    assert_eq "$(launchd_env CODEX_HOME)" "$T_HOME/.codex-profiles/work" "launchd 照样设置（回答：$answer）"
    [[ $(chatgpt_app_calls) != *quit* ]] || fail "拒绝时不应退出桌面 App（回答：$answer）"
    chatgpt_app_running || fail "桌面 App 仍在运行"
  done
}

test_no_input_counts_as_declined() {
  t_codex_profile work
  t_chatgpt_app running
  t_ccp chatgpt use work
  assert_rc 0
  [[ $(chatgpt_app_calls) != *quit* ]] || fail "读不到回答时不应退出桌面 App"
}

test_restart_flag_skips_question() {
  t_codex_profile work
  t_chatgpt_app running
  t_ccp chatgpt use --restart work
  assert_rc 0
  assert_stderr_empty
  [[ $T_OUT != *"[y/N]"* ]] || fail "--restart 不应询问"
  assert_eq "$(< $T_CHATGPT_APP/running)" "$T_HOME/.codex-profiles/work" "重新打开的桌面 App 使用新档案"
}

test_restart_to_default_reopens_without_codex_home() {
  t_codex_profile work
  t_codex_active work
  t_launchd_env CODEX_HOME "$T_HOME/.codex-profiles/work"
  t_chatgpt_app running
  t_ccp chatgpt use default --restart
  assert_rc 0
  assert_eq "${${(f)$(chatgpt_app_calls)}[-1]}" "open com.openai.codex" "最后重新打开桌面 App"
  assert_eq "$(_fake_field $T_CHATGPT_APP/calls/$(_fake_calls $T_CHATGPT_APP/calls) launchd_codex_home_set)" no \
    "重新打开时 launchd 里已没有 CODEX_HOME"
}

test_no_restart_flag_skips_question_and_keeps_app_running() {
  t_codex_profile work
  t_chatgpt_app running
  t_stdin y
  t_ccp chatgpt use work --no-restart
  assert_rc 0
  assert_stderr_empty
  [[ $T_OUT != *"[y/N]"* ]] || fail "--no-restart 不应询问"
  assert_contains "$T_OUT" "下次打开" "说明下次打开时生效"
  [[ $(chatgpt_app_calls) != *quit* ]] || fail "--no-restart 不应退出桌面 App"
}

test_quit_not_authorized_still_switches_and_gives_manual_steps() {
  t_codex_profile work
  t_chatgpt_app running deny
  t_ccp chatgpt use work --restart
  assert_rc 0
  assert_eq "$(< $(ACTIVE))" work "档案照样切换"
  assert_eq "$(launchd_env CODEX_HOME)" "$T_HOME/.codex-profiles/work" "launchd 照样设置"
  assert_contains "$T_ERR" "请手动退出 ChatGPT 后重新打开" "提示手动重启"
  assert_contains "$T_ERR" "ccp chatgpt use work --restart" "给出可复制的命令"
  assert_contains "$T_ERR" "自动化" "说明去哪里允许"
  [[ $(chatgpt_app_calls) != *"open com.openai.codex"* ]] || fail "没退出就不应重新打开"
}

test_app_that_does_not_quit_in_time_is_given_up_on() {
  t_codex_profile work
  t_chatgpt_app running ignore-quit
  t_ccp CCP_CHATGPT_QUIT_TIMEOUT=0.5 chatgpt use work --restart
  assert_rc 0
  assert_contains "$T_ERR" "放弃" "说明已放弃重启"
  assert_contains "$T_ERR" "0.5 秒" "说明等了多久"
  [[ $(chatgpt_app_calls) != *"open com.openai.codex"* ]] || fail "没退出就不应重新打开"
  assert_eq "$(< $(ACTIVE))" work "档案照样切换"
}

test_reopen_failure_is_reported_as_warning() {
  t_codex_profile work
  t_chatgpt_app running open-exit
  t_ccp chatgpt use work --restart
  assert_rc 0
  assert_contains "$T_ERR" "手动打开 ChatGPT" "提示手动打开"
}

# ---------- Claude Code 一侧不受影响 ----------

test_chatgpt_use_does_not_touch_claude_record() {
  t_profile work
  t_active work
  t_codex_profile personal
  t_ccp chatgpt use personal
  assert_rc 0
  assert_eq "$(< $T_HOME/.claude-profiles/active)" work "Claude 当前档案不变"
}

test_claude_use_does_not_touch_launchd_or_chatgpt() {
  t_profile work
  t_codex_profile work
  t_codex_active default
  t_chatgpt_app running
  t_ccp use work
  assert_rc 0
  assert_eq "$(launchctl_calls)" 0 "ccp use 不调用 launchctl"
  assert_eq "$(chatgpt_app_calls)" "" "ccp use 不碰桌面 App"
  assert_eq "$(< $(ACTIVE))" default "ChatGPT 当前档案不变"
}

t_main "$@"
