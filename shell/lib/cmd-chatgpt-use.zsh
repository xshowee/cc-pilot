# ccp chatgpt use <名字> [--restart|--no-restart]（别名 ccp codex use）：切换 ChatGPT 当前档案（ADR 0005）。
# lib/cmd-chatgpt.zsh 分派到 use 时 source 本文件并调用 _ccp_cmd_chatgpt_use。
#
# 切换逻辑只在这里实现一份：App 点击 ChatGPT 档案时也是在后台执行本命令（带 --restart 或 --no-restart），
# App 启动时执行 `ccp chatgpt use <当前档案> --no-restart` 恢复重启后丢失的 launchd 环境变量（本命令是幂等的）。
#
# 依次：
#   1. 检查名字（规则与 ccp use 相同）；不合规、是保留名、档案不存在时报错，什么都不改，返回 1。
#   2. 写当前档案记录 ~/.codex-profiles/active（格式、原子写入方式与 ccp use 相同；default 也写入）。
#   3. launchctl setenv CODEX_HOME <档案目录>（default 时 launchctl unsetenv CODEX_HOME）：之后经 LaunchServices
#      打开的 App（Dock、Spotlight、open、Zed 等）使用新档案。失败时报错返回 1（记录已经改了，codex 包装函数照样跟随）。
#   4. ChatGPT 桌面 App（bundle com.openai.codex）正在运行时：询问"重启 ChatGPT？[y/N]"（--restart / --no-restart
#      不询问）。重启 = 请它正常退出、等它退出（超时则放弃并说明）、再 open -b 重新打开（继承 launchd 里的新值）。
#      退出被拒（macOS 自动化授权）、超时、重新打开失败时不算失败：档案照样已经切换，在 stderr 说明怎么手动完成，
#      退出码仍为 0。所以带 --restart 运行时，stderr 非空就表示 ChatGPT 没有被重启（App 据此提示用户）。
#
# 外部程序 launchctl、osascript、open 都按 PATH 查找（测试在 PATH 最前面放假程序，见 tests/fakes/）。
# 桌面 App 退出后它的 codex app-server 守护进程仍在运行；重启时是否一并停止它待真机实测（ticket 04），目前不停止。
#
# 环境变量 CCP_CHATGPT_QUIT_TIMEOUT：等待桌面 App 退出的秒数，默认 15（测试用它缩短等待）。

_ccp_cmd_chatgpt_use() {
  emulate -L zsh
  local name= restart=ask arg choice
  integer count=0
  for arg in "$@"; do
    case $arg in
      (--restart|--no-restart)
        if [[ $arg == --restart ]]; then choice=yes; else choice=no; fi
        if [[ $restart != ask && $restart != $choice ]]; then
          print -u2 -r -- "ccp chatgpt use: --restart 和 --no-restart 只能选一个"
          print -u2
          _ccp_chatgpt_usage >&2
          return 2
        fi
        restart=$choice
        ;;
      (-*)
        print -u2 -r -- "ccp chatgpt use: 未知选项 \"$arg\""
        print -u2
        _ccp_chatgpt_usage >&2
        return 2
        ;;
      (*)
        (( count++ ))
        name=$arg
        ;;
    esac
  done
  if (( count != 1 )); then
    print -u2 -r -- "ccp chatgpt use: 需要且只需要一个档案名"
    print -u2
    _ccp_chatgpt_usage >&2
    return 2
  fi

  local dir=
  if [[ $name != default ]]; then
    if ! _ccp_valid_name "$name" || _ccp_reserved_name "$name"; then
      print -u2 -r -- "ccp chatgpt use: 档案名 $(_ccp_invalid_name_reason "$name")。"
      return 1
    fi
    dir=$(_ccp_chatgpt_profile_dir "$name")
    if ! _ccp_chatgpt_profile_exists "$name"; then
      print -u2 -r -- "ccp chatgpt use: 档案 \"$name\" 不存在（$dir）。"
      local variant=$(_ccp_chatgpt_profile_case_variant "$name")
      [[ -n $variant ]] && print -u2 -r -- "  档案名区分大小写：已有的档案是 \"$variant\"。"
      print -u2 -r -- "  用 \`ccp chatgpt ls\` 查看已有档案，或用 \`ccp chatgpt add $name\` 新建档案。"
      return 1
    fi
  fi

  _ccp_chatgpt_write_active "$name" || return 1

  if [[ -z $dir ]]; then
    launchctl unsetenv CODEX_HOME
  else
    launchctl setenv CODEX_HOME "$dir"
  fi
  if (( $? != 0 )); then
    print -u2 -r -- "ccp chatgpt use: 当前档案记录已改为 $name，但没能用 launchctl 设置 CODEX_HOME：之后打开的 ChatGPT 桌面 App 仍使用之前的档案（终端里新启动的 codex 不受影响）。"
    return 1
  fi
  print -r -- "ChatGPT 当前档案已切换为 $name。之后新启动的 codex 和之后打开的 ChatGPT 会使用它；已在运行的 codex 会话不受影响。"

  _ccp_chatgpt_app_running || return 0
  if [[ $restart == ask ]]; then
    local answer
    print -rn -- "ChatGPT 正在运行，重启后才会使用新档案，正在进行的任务会中断。重启 ChatGPT？[y/N] "
    if IFS= read -r answer && [[ $answer == ([yY]|[yY][eE][sS]) ]]; then
      restart=yes
    else
      [[ -n $answer ]] || print
      restart=no
    fi
  fi
  if [[ $restart == no ]]; then
    print -r -- "没有重启 ChatGPT：它下次打开时使用新档案。"
    return 0
  fi
  _ccp_chatgpt_restart_app "$name"
  return 0
}

# 原子写入 ChatGPT 当前档案记录（与 ccp use 写 Claude 记录的方式相同）。失败时报错返回 1，记录不变。
_ccp_chatgpt_write_active() {
  emulate -L zsh
  local root record tmp
  root=$(_ccp_chatgpt_profiles_root)
  record=$(_ccp_chatgpt_active_file)
  # rename 到一个目录（或指向目录的软链接）会把文件移进目录里，必须先拦住
  if [[ -d $record ]]; then
    print -u2 -r -- "ccp chatgpt use: 当前档案记录的位置 $record 是一个目录，请先手动处理它。"
    return 1
  fi
  if ! /bin/mkdir -p -- "$root" || ! tmp=$(/usr/bin/mktemp "$root/.active.XXXXXX"); then
    print -u2 -r -- "ccp chatgpt use: 无法在 $root 里写入当前档案记录。"
    return 1
  fi
  if ! print -r -- "$1" > "$tmp" || ! /bin/mv -f -- "$tmp" "$record"; then
    /bin/rm -f -- "$tmp"
    print -u2 -r -- "ccp chatgpt use: 写入当前档案记录 $record 失败，记录保持不变。"
    return 1
  fi
}

# ChatGPT 桌面 App 是否正在运行。查询本身不需要自动化授权；查询失败（例如没装 ChatGPT）按没在运行处理。
_ccp_chatgpt_app_running() {
  emulate -L zsh
  [[ $(osascript -e 'application id "com.openai.codex" is running' 2>/dev/null) == true ]]
}

# 退出并重新打开 ChatGPT 桌面 App。做不到时在 stderr 说明怎么手动完成，总是返回 0（档案已经切换）。
_ccp_chatgpt_restart_app() {
  emulate -L zsh
  zmodload -F zsh/datetime p:EPOCHREALTIME
  local name=$1 err
  local again="ccp chatgpt use $name --restart"
  print -r -- "正在退出 ChatGPT……"
  if ! err=$(osascript -e 'tell application id "com.openai.codex" to quit' 2>&1 >/dev/null); then
    if [[ $err == *"(-1743)"* ]]; then
      print -u2 -r -- "ccp chatgpt use: 没有退出 ChatGPT 的权限（macOS 自动化授权被拒绝）。档案已经切换，请手动退出 ChatGPT 后重新打开。"
      print -u2 -r -- "  也可以在“系统设置 > 隐私与安全性 > 自动化”里允许后再执行：$again"
    else
      print -u2 -r -- "ccp chatgpt use: 没能退出 ChatGPT（${err:-osascript 失败}）。档案已经切换，请手动退出 ChatGPT 后重新打开，或再执行：$again"
    fi
    return 0
  fi

  local timeout=${CCP_CHATGPT_QUIT_TIMEOUT-15}
  [[ $timeout == <->(.<->|) ]] || timeout=15
  local deadline=$(( EPOCHREALTIME + timeout ))
  while _ccp_chatgpt_app_running; do
    if (( EPOCHREALTIME >= deadline )); then
      print -u2 -r -- "ccp chatgpt use: ChatGPT 没有在 $timeout 秒内退出（可能在等你确认），已放弃重启。档案已经切换，ChatGPT 退出后重新打开即可使用新档案，或再执行：$again"
      return 0
    fi
    /bin/sleep 0.2
  done

  if ! open -b com.openai.codex; then
    print -u2 -r -- "ccp chatgpt use: ChatGPT 已退出，但没能重新打开它。档案已经切换，请手动打开 ChatGPT。"
    return 0
  fi
  print -r -- "已重新打开 ChatGPT，它现在使用档案 $name。"
}
