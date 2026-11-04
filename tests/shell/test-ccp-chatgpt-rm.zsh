#!/bin/zsh -f
# ccp chatgpt rm <名字>（别名 ccp codex rm）：删除 ChatGPT 档案（chatgpt-profiles ticket 06）。
# 拒绝默认档案、当前档案、launchd 里 CODEX_HOME 仍指向的档案；确认后先停止该档案的守护进程（codex app-server），
# 再由 codex 自己登出（CODEX_HOME=<目录> codex logout），auth.json 已不在才删除档案目录，只删软链接本身。
# codex、launchctl、ps 都是假的（tests/fakes/）；守护进程是测试自己启动的真进程，假 ps 把它列出来。
source "${0:A:h}/lib.zsh"

PROFILE() { print -r -- "$T_HOME/.codex-profiles/$1" }

# 按 ccp chatgpt add 的布局建一个已登录的档案：共享项是指向 ~/.codex 的绝对软链接，
# ~/.codex 里的共享内容各放一个文件，档案自己有 config.toml、auth.json、installation_id 和 sqlite/
t_signed_in_profile() {
  local name=$1 dir item
  dir=$(PROFILE $name)
  mkdir -p -- "$dir/sqlite" "$T_HOME/.codex" || exit 1
  for item in sessions archived_sessions thread-writer-locks .tmp skills plugins rules; do
    mkdir -p -- "$T_HOME/.codex/$item" || exit 1
    print -r -- keep > "$T_HOME/.codex/$item/data" || exit 1
    ln -s -- "$T_HOME/.codex/$item" "$dir/$item" || exit 1
  done
  print -r -- "# shared" > "$T_HOME/.codex/AGENTS.md" || exit 1
  ln -s -- "$T_HOME/.codex/AGENTS.md" "$dir/AGENTS.md" || exit 1
  print -r -- "sqlite_home = \"$T_HOME/.codex\"" > "$dir/config.toml" || exit 1
  print -r -- '{"auth_mode":"chatgpt"}' > "$dir/auth.json" || exit 1
  print -r -- id > "$dir/installation_id" || exit 1
  print -r -- db > "$dir/sqlite/codex.db" || exit 1
}

# ~/.codex 里的共享内容全部完好
assert_shared_intact() {
  local item
  for item in sessions archived_sessions thread-writer-locks .tmp skills plugins rules; do
    [[ -d $T_HOME/.codex/$item && ! -L $T_HOME/.codex/$item ]] || fail "~/.codex/$item 应保留"
    assert_eq "$(< $T_HOME/.codex/$item/data)" keep "~/.codex/$item 里的内容应保留"
  done
  assert_eq "$(< $T_HOME/.codex/AGENTS.md)" "# shared" "~/.codex/AGENTS.md 应保留"
}

assert_profile_intact() {  # 名字
  [[ -f $(PROFILE $1)/auth.json ]] || fail "档案 $1 应保持原样（auth.json 还在）"
  [[ -L $(PROFILE $1)/sessions ]] || fail "档案 $1 应保持原样（软链接还在）"
}

assert_not_logged_out() {
  assert_codex_calls 0
}

# 档案 $1 的守护进程在假 ps 里的一行：codex app-server，环境里 CODEX_HOME 指向档案目录
daemon_line() {  # 档案名 [CODEX_HOME 的值]
  print -r -- "$T_HOME/.codex-profiles/$1/packages/app-server-daemon/0.166.0/codex app-server --listen stdio:// HOME=$T_HOME CODEX_HOME=${2:-$(PROFILE $1)} __CFBundleIdentifier=com.openai.codex"
}

# ---------- 删除 ----------

test_confirmed_removal_logs_out_with_codex_then_deletes_profile() {
  t_signed_in_profile work
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  assert_codex_calls 1
  assert_codex_home "$(PROFILE work)"
  assert_codex_args logout
  [[ ! -e $(PROFILE work) && ! -L $(PROFILE work) ]] || fail "档案目录应已删除"
  assert_contains "$T_OUT" '"work"' "应说明删除了哪个档案"
}

test_removal_keeps_shared_content_in_default_profile() {
  t_signed_in_profile work
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  assert_shared_intact
  [[ -d $T_HOME/.codex-profiles ]] || fail "档案根目录应保留"
}

test_codex_alias_also_removes() {
  t_signed_in_profile work
  t_stdin yes
  t_ccp codex rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) ]] || fail "ccp codex rm 应删除档案"
}

test_profile_never_signed_in_is_removed() {
  # 没有 auth.json：登出照样执行（codex 自己决定），之后没有凭据就删除
  t_signed_in_profile work
  rm -f -- "$(PROFILE work)/auth.json"
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_logout_ignores_codex_profile_and_codex_home_in_environment() {
  t_signed_in_profile work
  t_codex_profile other
  t_stdin y
  t_ccp CODEX_PROFILE=other CODEX_HOME="$(PROFILE other)" -- chatgpt rm work
  assert_rc 0
  assert_codex_home "$(PROFILE work)"
}

test_profile_dir_that_is_a_symlink_removes_only_the_link() {
  t_signed_in_profile real
  mv -- "$(PROFILE real)" "$T/elsewhere" || exit 1
  ln -s -- "$T/elsewhere" "$(PROFILE work)" || exit 1
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) && ! -L $(PROFILE work) ]] || fail "软链接本身应被删除"
  [[ -f $T/elsewhere/config.toml ]] || fail "不应跟随档案目录的软链接删除它指向的内容"
  assert_shared_intact
}

# ---------- 确认 ----------

test_asks_for_confirmation_and_cancel_changes_nothing() {
  t_signed_in_profile work
  t_stdin n
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_OUT" '"work"' "确认提示里应有档案名"
  assert_contains "$T_OUT" "[y/N]" "应询问用户"
  assert_contains "$T_OUT" "已取消" "拒绝后应说明没有删除"
  assert_stderr_empty
  assert_not_logged_out
  assert_profile_intact work
}

test_no_answer_counts_as_cancel() {
  t_signed_in_profile work
  t_ccp chatgpt rm work
  assert_rc 1
  assert_not_logged_out
  assert_profile_intact work
}

# ---------- 登出失败 ----------

test_logout_failure_keeps_profile_and_explains() {
  t_signed_in_profile work
  t_stdin y
  t_ccp FAKE_CODEX_EXIT=4 -- chatgpt rm work
  assert_rc 1
  assert_codex_calls 1
  assert_profile_intact work
  assert_contains "$T_ERR" "auth.json" "应说明凭据还在"
  assert_contains "$T_ERR" "没有删除" "应说明没有删除"
  assert_shared_intact
}

test_auth_json_reappearing_after_logout_keeps_profile() {
  # codex 返回 0 但 auth.json 仍在（例如被别的进程写回）：只看 auth.json，不删除
  t_signed_in_profile work
  t_stdin y
  t_ccp FAKE_CODEX_HOOK='print -r -- "{}" > "$CODEX_HOME/auth.json"' -- chatgpt rm work
  assert_rc 1
  assert_profile_intact work
  assert_contains "$T_ERR" "auth.json" "应说明凭据还在"
}

test_missing_codex_command_keeps_profile() {
  t_signed_in_profile work
  t_stdin y
  # PATH 里只去掉假 codex，其他假程序照旧（系统里也没有真 codex 可找：只留系统目录）
  mkdir -p -- $T/fakes-no-codex || exit 1
  local f
  for f in $FAKES/*(.x); do [[ ${f:t} == codex ]] || ln -s -- $f $T/fakes-no-codex/${f:t}; done
  t_ccp PATH="$T/fakes-no-codex:/usr/bin:/bin:/usr/sbin:/sbin" -- chatgpt rm work
  assert_rc 1
  assert_profile_intact work
  assert_contains "$T_ERR" "codex" "应说明找不到 codex"
}

# ---------- 拒绝（都在询问之前，什么都不做） ----------

test_default_profile_cannot_be_removed() {
  t_codex_default
  t_stdin y
  t_ccp chatgpt rm default
  assert_rc 1
  assert_contains "$T_ERR" "默认档案" "应说明默认档案不能删除"
  assert_not_logged_out
  [[ -d $T_HOME/.codex ]] || fail "默认档案应保留"
}

test_current_profile_cannot_be_removed() {
  t_signed_in_profile work
  t_codex_active work
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_ERR" "当前档案" "应说明是当前档案"
  assert_contains "$T_ERR" "ccp chatgpt use" "应提示先切换"
  assert_not_logged_out
  assert_profile_intact work
}

test_current_record_differing_only_in_case_still_blocks_removal() {
  # 记录写的是 Work，目录是 work：在不分大小写的文件系统上是同一个目录
  t_signed_in_profile work
  t_codex_active Work
  [[ $(PROFILE Work) -ef $(PROFILE work) ]] || return 0  # 区分大小写的文件系统上不适用
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_ERR" "当前档案" "应说明是当前档案"
  assert_profile_intact work
}

test_profile_launchd_still_points_to_cannot_be_removed() {
  t_signed_in_profile work
  t_launchd_env CODEX_HOME "$(PROFILE work)"
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_ERR" "launchd" "应说明 launchd 里的 CODEX_HOME 仍指向它"
  assert_contains "$T_ERR" "ccp chatgpt use" "应提示怎么让 launchd 跟上当前档案"
  assert_not_logged_out
  assert_profile_intact work
  assert_eq "$(launchd_env CODEX_HOME)" "$(PROFILE work)" "不应改动 launchd 环境"
}

test_launchd_value_with_trailing_slash_still_blocks_removal() {
  t_signed_in_profile work
  t_launchd_env CODEX_HOME "$(PROFILE work)/"
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_ERR" "launchd" "应说明 launchd 里的 CODEX_HOME 仍指向它"
  assert_profile_intact work
}

test_launchd_pointing_to_another_profile_does_not_block() {
  t_signed_in_profile work
  t_codex_profile other
  t_launchd_env CODEX_HOME "$(PROFILE other)"
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_unreadable_launchd_environment_blocks_removal() {
  # launchctl 失败：无法确认 GUI 入口不再使用这个档案，保守地拒绝
  t_signed_in_profile work
  mkdir -p -- $T_LAUNCHD && print -r -- 5 > $T_LAUNCHD/exit
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_ERR" "launchctl" "应说明 launchctl 失败"
  assert_not_logged_out
  assert_profile_intact work
}

test_missing_profile_reports_error_with_case_hint() {
  t_signed_in_profile work
  t_stdin y
  t_ccp chatgpt rm Work
  [[ $(PROFILE Work) -ef $(PROFILE work) ]] || { assert_rc 1; return 0 }
  assert_rc 1
  assert_contains "$T_ERR" "不存在" "应说明档案不存在"
  assert_contains "$T_ERR" '"work"' "应提示已有的、只差大小写的档案名"
  assert_not_logged_out
  assert_profile_intact work
}

test_missing_profile_reports_error() {
  t_codex_default
  t_stdin y
  t_ccp chatgpt rm ghost
  assert_rc 1
  assert_contains "$T_ERR" "不存在" "应说明档案不存在"
  assert_contains "$T_ERR" "ccp chatgpt ls" "应提示怎么查看已有档案"
  assert_not_logged_out
}

test_malformed_name_is_rejected() {
  t_codex_default
  t_stdin y
  t_ccp chatgpt rm ../.codex
  assert_rc 1
  assert_contains "$T_ERR" "不合规" "应说明名字不合规"
  assert_not_logged_out
  [[ -d $T_HOME/.codex ]] || fail "默认档案应保留"
}

test_wrong_argument_count_prints_usage() {
  t_ccp chatgpt rm
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法"
  t_ccp chatgpt rm a b
  assert_rc 2
}

# ---------- 守护进程（codex app-server） ----------

test_running_daemon_is_mentioned_and_stopped_before_logout() {
  t_signed_in_profile work
  local pid
  pid=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $pid "$(daemon_line work)"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $pid && { alive=1; kill -KILL $pid 2>/dev/null }
  assert_rc 0
  assert_eq $alive 0 "守护进程应已停止"
  assert_contains "$T_OUT" "守护进程" "确认前应说明会停止守护进程"
  assert_contains "$T_OUT" "$pid" "应列出守护进程的 PID"
  assert_codex_args logout
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_daemon_that_does_not_stop_keeps_profile_and_skips_logout() {
  t_signed_in_profile work
  local pid
  pid=$(t_spawn 'trap "" TERM; while :; do /bin/sleep 0.1; done')
  t_ps_process $pid "$(daemon_line work)"
  t_stdin y
  t_ccp CCP_CHATGPT_DAEMON_TIMEOUT=1 -- chatgpt rm work
  local alive=0
  process_alive $pid && { alive=1; kill -KILL $pid 2>/dev/null }
  assert_rc 1
  assert_eq $alive 1 "不应强制结束守护进程"
  assert_contains "$T_ERR" "守护进程" "应说明守护进程没有停止"
  assert_contains "$T_ERR" "$pid" "应给出守护进程的 PID"
  assert_contains "$T_ERR" "没有删除" "应说明没有删除"
  assert_not_logged_out
  assert_profile_intact work
}

test_cancel_leaves_running_daemon_alone() {
  t_signed_in_profile work
  local pid
  pid=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $pid "$(daemon_line work)"
  t_stdin n
  t_ccp chatgpt rm work
  local alive=0
  process_alive $pid && { alive=1; kill -KILL $pid 2>/dev/null }
  assert_rc 1
  assert_eq $alive 1 "取消时不应停止守护进程"
  assert_profile_intact work
}

test_other_profiles_processes_do_not_block_or_get_stopped() {
  # 其他档案的守护进程、CODEX_HOME 只是前缀相同的进程（work2）都不算在用 work，也不动
  t_signed_in_profile work
  t_codex_profile work2
  local other prefix
  other=$(t_spawn 'exec /bin/sleep 60')
  prefix=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $other "$(daemon_line work2)"
  t_ps_process $prefix "/opt/homebrew/bin/codex resume HOME=$T_HOME CODEX_HOME=$(PROFILE work)2"
  t_stdin y
  t_ccp chatgpt rm work
  local -a survivors=()
  local p
  for p in $other $prefix; do
    process_alive $p && { survivors+=($p); kill -KILL $p 2>/dev/null }
  done
  assert_rc 0
  assert_eq "${survivors[*]}" "$other $prefix" "其他进程都应继续运行"
  assert_not_contains_daemon_notice
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_daemon_is_recognized_by_its_install_path_even_without_codex_home() {
  # 守护进程按可执行文件在 <档案>/packages/app-server-daemon/ 下识别；读不到它的 CODEX_HOME 也照样确认后停止
  t_signed_in_profile work
  local pid
  pid=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $pid "$(PROFILE work)/packages/app-server-daemon/0.166.0/codex app-server --listen stdio://"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $pid && { alive=1; kill -KILL $pid 2>/dev/null }
  assert_rc 0
  assert_eq $alive 0 "守护进程应已停止"
  assert_contains "$T_OUT" "$pid" "应列出守护进程的 PID"
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_other_app_server_processes_block_removal_and_are_left_running() {
  # VS Code / IDE 的 Codex 扩展也跑 codex app-server，其他程序也可能带 app-server 参数：都不是桌面 App 的
  # 守护进程，算"在用"——询问之前拒绝，不停止
  t_signed_in_profile work
  local ide tool
  ide=$(t_spawn 'exec /bin/sleep 60')
  tool=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $ide "/Users/me/.vscode/extensions/openai.chatgpt-26.5.0/bin/macos-aarch64/codex app-server --analytics-default-enabled HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_ps_process $tool "/opt/tools/agent-bridge app-server --port 9 HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_stdin y
  t_ccp chatgpt rm work
  local -a survivors=()
  local p
  for p in $ide $tool; do
    process_alive $p && { survivors+=($p); kill -KILL $p 2>/dev/null }
  done
  assert_refused_in_use work
  assert_eq "${survivors[*]}" "$ide $tool" "不应停止它们"
  assert_contains "$T_ERR" "$ide" "应列出 IDE 扩展的 app-server"
  assert_contains "$T_ERR" "$tool" "应列出其他 app-server 进程"
  assert_contains "$T_ERR" "agent-bridge" "应列出命令名"
}

# 询问之后到停止之间进程表可能变了（询问不限时）：确认后重新列一次进程，只停止仍是本档案守护进程的 PID

test_pid_reused_after_confirmation_is_not_stopped() {
  # 询问时 PID 是守护进程；确认时守护进程已退出，PID 被不相干的进程重用：不能停它
  t_signed_in_profile work
  local pid
  pid=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $pid "$(daemon_line work)"
  t_ps_process_at 2 $pid "/bin/sleep 60 HOME=$T_HOME"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $pid && { alive=1; kill -KILL $pid 2>/dev/null }
  assert_eq $alive 1 "重用了 PID 的进程不应被停止"
  assert_rc 0
  assert_eq "$(ps_calls)" 2 "确认后应重新列一次进程"
  assert_codex_args logout
  [[ ! -e $(PROFILE work) ]] || fail "守护进程已经不在，档案目录应已删除"
}

test_process_started_using_profile_during_confirmation_blocks_removal() {
  t_signed_in_profile work
  local daemon
  daemon=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $daemon "$(daemon_line work)"
  t_ps_process_at 2 $daemon "$(daemon_line work)"
  t_ps_process_at 2 4280 "/opt/homebrew/bin/codex HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $daemon && { alive=1; kill -KILL $daemon 2>/dev/null }
  assert_rc 1
  assert_eq $alive 1 "拒绝时不应停止守护进程"
  assert_contains "$T_ERR" "4280" "应列出在用的进程"
  assert_contains "$T_ERR" "没有删除" "应说明没有删除"
  assert_not_logged_out
  assert_profile_intact work
}

test_daemon_started_during_confirmation_blocks_removal() {
  # 询问时没有提到的守护进程（询问之后才启动的）：没经过确认，不停止，也不删除
  t_signed_in_profile work
  local daemon
  daemon=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process_at 1
  t_ps_process_at 2 $daemon "$(daemon_line work)"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $daemon && { alive=1; kill -KILL $daemon 2>/dev/null }
  assert_rc 1
  assert_eq $alive 1 "没确认过的守护进程不应停止"
  assert_contains "$T_ERR" "$daemon" "应给出守护进程的 PID"
  assert_contains "$T_ERR" "ccp chatgpt rm work" "应提示重新执行"
  assert_not_logged_out
  assert_profile_intact work
}

test_process_listing_failure_after_confirmation_blocks_removal() {
  t_signed_in_profile work
  local daemon
  daemon=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $daemon "$(daemon_line work)"
  mkdir -p -- $T_PS && print -r -- 1 > $T_PS/exit.2
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $daemon && { alive=1; kill -KILL $daemon 2>/dev/null }
  assert_rc 1
  assert_eq $alive 1 "无法确认时不应停止守护进程"
  assert_contains "$T_ERR" "没有删除" "应说明没有删除"
  assert_not_logged_out
  assert_profile_intact work
}

assert_not_contains_daemon_notice() {
  [[ $T_OUT != *守护进程* ]] || fail "没有本档案的守护进程时不应提到守护进程：$T_OUT"
}

# ---------- 还有 codex 进程或 ChatGPT 桌面 App 在用这个档案（环境里的 CODEX_HOME 指向它）：询问之前拒绝 ----------

# 拒绝时：退出码 1、没有询问、没有登出、档案原样、只查了一次进程表
assert_refused_in_use() {  # 档案名
  assert_rc 1
  [[ $T_OUT != *"[y/N]"* ]] || fail "拒绝时不应询问：$T_OUT"
  assert_not_logged_out
  assert_profile_intact $1
  assert_eq "$(ps_calls)" 1 "应只列一次进程"
  assert_contains "$T_ERR" "没有删除" "应说明没有删除"
  assert_contains "$T_ERR" "ccp chatgpt rm $1" "应提示退出这些进程后重新执行"
}

test_codex_session_using_profile_blocks_removal() {
  t_signed_in_profile work
  t_ps_process 4242 "/opt/homebrew/bin/codex resume HOME=$T_HOME CODEX_HOME=$(PROFILE work) TERM=xterm"
  t_stdin y
  t_ccp chatgpt rm work
  assert_refused_in_use work
  assert_contains "$T_ERR" "4242" "应列出进程的 PID"
  assert_contains "$T_ERR" "codex" "应列出进程的命令名"
  [[ $T_ERR != *"/opt/homebrew/bin/codex"* ]] || fail "只列命令名，不列完整路径：$T_ERR"
  [[ $T_ERR != *"TERM=xterm"* ]] || fail "不应列出进程的环境：$T_ERR"
}

test_other_codex_named_process_blocks_removal() {
  # 名字以 codex 开头的都算（codex-acp 等），与 ChatGPTSessionWriters 的口径一致
  t_signed_in_profile work
  t_ps_process 4250 "/usr/local/bin/codex-acp --stdio HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_stdin y
  t_ccp chatgpt rm work
  assert_refused_in_use work
  assert_contains "$T_ERR" "4250" "应列出进程的 PID"
  assert_contains "$T_ERR" "codex-acp" "应列出进程的命令名"
}

test_desktop_app_using_profile_blocks_removal_and_is_left_running() {
  t_signed_in_profile work
  local app
  app=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $app "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT HOME=$T_HOME CODEX_HOME=$(PROFILE work)/"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $app && { alive=1; kill -KILL $app 2>/dev/null }
  assert_refused_in_use work
  assert_eq $alive 1 "不应停止在用这个档案的进程"
  assert_contains "$T_ERR" "$app" "应列出桌面 App 的 PID"
  assert_contains "$T_ERR" "ChatGPT" "应说明是 ChatGPT 桌面 App"
}

test_desktop_app_helper_blocks_removal() {
  # Electron helper 的可执行文件也在 ChatGPT.app/ 里（路径带空格；App 装在别处也一样）
  t_signed_in_profile work
  t_ps_process 4251 "/Users/me/My Apps/ChatGPT.app/Contents/Frameworks/ChatGPT Helper (Renderer).app/Contents/MacOS/ChatGPT Helper (Renderer) --type=renderer HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_stdin y
  t_ccp chatgpt rm work
  assert_refused_in_use work
  assert_contains "$T_ERR" "4251" "应列出 helper 的 PID"
  assert_contains "$T_ERR" "ChatGPT" "应说明是 ChatGPT 桌面 App"
}

test_programs_that_merely_inherited_codex_home_do_not_block() {
  # 在 launchd 指向 work 期间从 Dock 打开的 iTerm、VS Code、其中的 shell，以及 node 包装进程、
  # 守护进程派生的（不叫 codex 的）子进程：只是继承了 CODEX_HOME，并没有在用这个档案
  t_signed_in_profile work
  local -a lines=(
    "/Applications/iTerm.app/Contents/MacOS/iTerm2 HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
    "-zsh HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
    "/opt/homebrew/bin/zsh -l HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
    "/Applications/Visual Studio Code.app/Contents/MacOS/Electron HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
    "node /opt/homebrew/bin/codex HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
    "/opt/homebrew/bin/node /Users/me/mcp/server.js HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
    "/Applications/ChatGPTHelper.app/Contents/MacOS/x HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  )
  local -i pid=4260
  local line
  for line in $lines; do t_ps_process $(( pid++ )) "$line"; done
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_in_use_process_blocks_even_with_a_running_daemon() {
  # 守护进程照常能停，但别的进程还在用：仍在询问之前拒绝，守护进程也不动
  t_signed_in_profile work
  local daemon
  daemon=$(t_spawn 'exec /bin/sleep 60')
  t_ps_process $daemon "$(daemon_line work)"
  t_ps_process 4243 "/opt/homebrew/bin/codex HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_stdin y
  t_ccp chatgpt rm work
  local alive=0
  process_alive $daemon && { alive=1; kill -KILL $daemon 2>/dev/null }
  assert_refused_in_use work
  assert_eq $alive 1 "拒绝时不应停止守护进程"
  assert_contains "$T_ERR" "4243" "应列出在用的进程"
}

test_process_with_codex_home_pointing_elsewhere_does_not_block() {
  t_signed_in_profile work
  t_codex_profile other
  t_ps_process 4244 "/opt/homebrew/bin/codex HOME=$T_HOME CODEX_HOME=$(PROFILE other)"
  t_ps_process 4245 "/opt/homebrew/bin/node server.js HOME=$T_HOME CODEX_HOME=$T/somewhere/work"
  t_ps_process 4246 "/opt/homebrew/bin/node $(PROFILE work)/script.js HOME=$T_HOME"
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_ccp_run_with_profiles_codex_home_is_not_refused_for_that() {
  # 带着从 launchd 继承来的旧 CODEX_HOME 的终端里运行 ccp：ccp 和它启动的 ps 不算在用
  t_signed_in_profile work
  t_ps_process 4270 "/opt/homebrew/bin/zsh /Users/me/.cc-pilot/bin/ccp chatgpt rm work HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_ps_process 4271 "ps -A -E -ww -o pid= -o command= HOME=$T_HOME CODEX_HOME=$(PROFILE work)"
  t_stdin y
  t_ccp CODEX_HOME="$(PROFILE work)" -- chatgpt rm work
  assert_rc 0
  [[ ! -e $(PROFILE work) ]] || fail "档案目录应已删除"
}

test_process_listing_failure_blocks_removal() {
  t_signed_in_profile work
  mkdir -p -- $T_PS && print -r -- 1 > $T_PS/exit
  t_stdin y
  t_ccp chatgpt rm work
  assert_rc 1
  assert_contains "$T_ERR" "守护进程" "应说明无法确认守护进程是否在运行"
  assert_not_logged_out
  assert_profile_intact work
}

t_main "$@"
