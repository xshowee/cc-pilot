# ccp chatgpt rm <名字>（别名 ccp codex rm）：删除 ChatGPT 档案（chatgpt-profiles ticket 06）。
# lib/cmd-chatgpt.zsh 分派到 rm 时 source 本文件并调用 _ccp_cmd_chatgpt_rm；返回值即 ccp 的退出码。
#
# 流程（spec "共享资源 / 删除档案"）：
#   1. 拒绝（都在询问之前，什么都不做）：默认档案、名字不合规、当前档案（按是否同一个目录判断，同 ccp rm）、
#      档案不存在（给出大小写提示）、launchd 里的 CODEX_HOME 仍指向它（之后从 Dock 等打开的 ChatGPT 还会用它；
#      launchctl 失败时无法确认，同样拒绝）、无法列出进程（无法确认有没有进程在用它）。
#   2. 在环境里 CODEX_HOME 是该档案目录的进程中找真正在用它的：
#      - 桌面 App 的守护进程：命令行里还有 app-server 这个参数（装在 CODEX_HOME/packages/app-server-daemon/ 下，
#        App 退出后仍在运行）。按下面的流程确认后停止。
#      - codex 进程（命令名以 codex 开头，同 App 的 ChatGPTSessionWriters）和 ChatGPT 桌面 App 本体及其 helper
#        （可执行文件在 ChatGPT.app/ 里）：有任何一个就拒绝删除，列出 PID 和命令名，请用户退出它们后重试；
#        ccp 不停止它们。
#      其他进程即使带着这个 CODEX_HOME 也不算：在 launchd 指向该档案期间从 Dock 等打开的 iTerm、VS Code、
#      其中的 shell（包括 ccp 自己和它启动的 ps）只是继承了它（codex 包装函数也把继承来的值当作过期的），
#      守护进程派生的不叫 codex 的子进程随守护进程处理。
#   3. 询问一次 [y/N]（有守护进程时在同一个问题里说明会先停止它）；y / yes 才继续。
#   4. 停止守护进程：kill -TERM，每 0.2 秒看一次，最多等 CCP_CHATGPT_DAEMON_TIMEOUT 秒（默认 10）；
#      还在运行就不登出、不删除（不强制结束）。
#   5. CODEX_HOME=<目录> command codex logout（由 codex 自己撤销凭据；不经过包装函数，也不看 CODEX_PROFILE）。
#   6. <目录>/auth.json 仍存在（登出失败）时不删除；否则 rm -rf <目录>：rm 不跟随软链接，共享项只删链接本身，
#      ~/.codex 里的内容不受影响（档案目录本身是软链接时也只删这个链接）。
#
# 进程列表用 `ps -A -E -ww -o pid= -o command=`（-E 在命令行后面追加进程的环境变量，以空格分隔；
# 系统自带的程序看不到环境，codex 不是系统程序，看得到——见 shell/README.md 的 ccp chatgpt rm 一节）。ps 按 PATH 查找，测试换成假的。

_ccp_cmd_chatgpt_rm() {
  emulate -L zsh
  if (( $# != 1 )); then
    print -u2 -r -- "用法：ccp chatgpt rm <名字>"
    return 2
  fi
  local name=$1 dir active launchd variant answer entry
  local -a daemons users

  if [[ $name == default ]]; then
    print -u2 -r -- "ccp chatgpt rm: 默认档案（~/.codex）不能删除。"
    return 1
  fi
  if ! _ccp_valid_name "$name" || _ccp_reserved_name "$name"; then
    print -u2 -r -- "ccp chatgpt rm: 档案名 $(_ccp_invalid_name_reason "$name")。"
    return 1
  fi
  dir=$(_ccp_chatgpt_profile_dir "$name")
  active=$(_ccp_chatgpt_active_name)
  # 记录里的名字可能只与目录名差在大小写：按是否同一个目录判断（同 ccp rm）
  if [[ $name == "$active" ]] \
      || { [[ $active != default ]] && _ccp_valid_name "$active" \
           && [[ $(_ccp_chatgpt_profile_dir "$active") -ef $dir ]] }; then
    print -u2 -r -- "ccp chatgpt rm: \"$name\" 是 ChatGPT 的当前档案，不能删除。请先用 \`ccp chatgpt use <其他档案>\` 切换（例如 \`ccp chatgpt use default\`）。"
    return 1
  fi
  if ! _ccp_chatgpt_profile_exists "$name"; then
    print -u2 -r -- "ccp chatgpt rm: 档案 \"$name\" 不存在（$dir）。可以用 \`ccp chatgpt ls\` 查看已有档案。"
    variant=$(_ccp_chatgpt_profile_case_variant "$name")
    [[ -n $variant ]] && print -u2 -r -- "  档案名区分大小写：已有的档案是 \"$variant\"。"
    return 1
  fi

  if ! launchd=$(launchctl getenv CODEX_HOME 2>/dev/null); then
    print -u2 -r -- "ccp chatgpt rm: 无法用 launchctl 读取 launchd 里的 CODEX_HOME，不能确认之后打开的 ChatGPT 不再使用档案 \"$name\"，没有删除。"
    return 1
  fi
  if [[ -n $launchd ]] && { [[ ${launchd%/} == "$dir" ]] || [[ $launchd -ef $dir ]] }; then
    print -u2 -r -- "ccp chatgpt rm: launchd 里的 CODEX_HOME 仍指向档案 \"$name\"（之后从 Dock、Spotlight 打开的 ChatGPT 等会使用它），不能删除。"
    print -u2 -r -- "  请执行 \`ccp chatgpt use $(_ccp_chatgpt_active_name)\` 让 launchd 跟上当前档案，或用 \`ccp chatgpt use <其他档案>\` 切换后再删除。"
    return 1
  fi

  if ! _ccp_chatgpt_profile_processes "$dir"; then
    print -u2 -r -- "ccp chatgpt rm: 无法列出进程（ps 失败），不能确认是否还有进程（包括 ChatGPT 守护进程）在使用档案 \"$name\"，没有删除。"
    return 1
  fi

  if (( ${#users} )); then
    print -u2 -r -- "ccp chatgpt rm: 还有 codex 或 ChatGPT 桌面 App 在使用档案 \"$name\"（环境里的 CODEX_HOME 指向 $dir），没有删除："
    for entry in $users; do
      print -u2 -r -- "  PID ${entry%% *}  ${entry#* }"
    done
    print -u2 -r -- "  请退出 ChatGPT 桌面 App、结束在这个档案里运行的 codex 后重新执行 \`ccp chatgpt rm $name\`。"
    return 1
  fi

  if (( ${#daemons} )); then
    print -r -- "档案 \"$name\" 的 ChatGPT 守护进程（codex app-server，PID ${(j:, :)daemons}）正在运行，确认后会先停止它。"
  fi
  print -rn -- "确定要删除 ChatGPT 档案 \"$name\"（$dir）吗？会先在其中执行 codex logout。[y/N] "
  if ! IFS= read -r answer || [[ $answer != ([yY]|[yY][eE][sS]) ]]; then
    print -r -- "已取消，没有删除任何东西。"
    return 1
  fi

  if (( ${#daemons} )); then
    print -r -- "正在停止守护进程……"
    if ! _ccp_chatgpt_stop_processes $daemons; then
      print -u2 -r -- "ccp chatgpt rm: 档案 \"$name\" 的 ChatGPT 守护进程（PID ${(j:, :)reply}）在 ${CCP_CHATGPT_DAEMON_TIMEOUT:-10} 秒内没有退出，没有登出，也没有删除。"
      print -u2 -r -- "  请退出 ChatGPT 或结束这些进程后重新执行 \`ccp chatgpt rm $name\`。"
      return 1
    fi
  fi

  print -r -- "正在档案 \"$name\" 里执行 codex logout……"
  local -i rc
  CODEX_HOME=$dir command codex logout
  rc=$?
  if [[ -e $dir/auth.json || -L $dir/auth.json ]]; then
    if (( rc == 127 )) && (( ! $+commands[codex] )); then
      print -u2 -r -- "ccp chatgpt rm: 没有找到 codex 命令，无法登出。请先安装 Codex CLI。"
    fi
    print -u2 -r -- "ccp chatgpt rm: 登出没有成功（codex 退出码 $rc），档案 \"$name\" 的凭据 $dir/auth.json 仍在，没有删除。"
    print -u2 -r -- "  请处理后重新执行 \`ccp chatgpt rm $name\`。"
    return 1
  fi

  # 不带结尾的 /：rm 只删除软链接本身，不跟随它删除 ~/.codex 里的共享内容
  /bin/rm -rf -- "$dir" || {
    print -u2 -r -- "ccp chatgpt rm: 删除 $dir 失败。"
    return 1
  }
  print -r -- "已删除 ChatGPT 档案 \"$name\"。"
}

# 在环境里 CODEX_HOME 等于档案目录 $1（允许结尾多一个 /）的进程（不含 ccp 自己）中找在用它的，填进调用方的两个数组：
#   daemons  桌面 App 守护进程的 PID（命令行里还有 app-server 这个参数）
#   users    其他在用的进程，每个元素是 "PID 命令名"：
#            - codex 进程：命令行第一个词的最后一段（命令名）以 codex 开头（不分大小写），同 ChatGPTSessionWriters；
#              npm 装的 node 包装进程不算（真正用档案的是它启动的 codex）
#            - ChatGPT 桌面 App 本体及其 helper：可执行文件在 ChatGPT.app/ 里，即命令行里第一个 /ChatGPT.app/
#              之前没有 =（还没到参数里的 --x=y 和追加的环境变量；路径本身可以带空格），命令名记作"ChatGPT 桌面 App"
#            其他进程只是继承了这个 CODEX_HOME，不算（见文件头）。ps 失败时返回 1。
# ps 的命令行与环境以空格连接、不转义，所以按整行匹配 " CODEX_HOME=<目录>" 后面紧跟空格或行尾，不按空格拆分。
_ccp_chatgpt_profile_processes() {
  emulate -L zsh
  setopt extended_glob
  local dir=$1 out line pid rest word
  daemons=() users=()
  out=$(ps -A -E -ww -o pid= -o command= 2>/dev/null) || return 1
  for line in ${(f)out}; do
    line=${line##[[:space:]]#}
    pid=${line%%[[:space:]]*}
    rest=" ${line#*[[:space:]]} "
    [[ $pid == <-> && $pid != $$ ]] || continue
    [[ $rest == *" CODEX_HOME=$dir "* || $rest == *" CODEX_HOME=$dir/ "* ]] || continue
    word=${${rest# }%% *}
    if [[ $rest == *" app-server "* ]]; then
      daemons+=($pid)
    elif [[ ${(L)word:t} == codex* ]]; then
      users+=("$pid ${word:t}")
    elif [[ $rest == " /"*"/ChatGPT.app/"* && ${rest%%/ChatGPT.app/*} != *=* ]]; then
      users+=("$pid ChatGPT 桌面 App")
    fi
  done
  return 0
}

# 正常停止进程（参数：PID…）：发 TERM，每 0.2 秒检查一次，最多等 CCP_CHATGPT_DAEMON_TIMEOUT 秒（默认 10）。
# 全部退出返回 0；否则把还在运行的 PID 放进 reply，返回 1。不发 KILL。
_ccp_chatgpt_stop_processes() {
  emulate -L zsh
  local pid timeout=${CCP_CHATGPT_DAEMON_TIMEOUT:-10}
  [[ $timeout == <-> ]] || timeout=10
  local -i tries=$(( timeout * 5 ))
  kill -TERM "$@" 2>/dev/null
  while :; do
    reply=()
    for pid in "$@"; do kill -0 $pid 2>/dev/null && reply+=($pid); done
    (( ${#reply} == 0 )) && return 0
    (( tries-- > 0 )) || return 1
    /bin/sleep 0.2
  done
}
