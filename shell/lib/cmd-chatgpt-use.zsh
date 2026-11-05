# ccp chatgpt use <名字>（别名 ccp codex use）：切换 ChatGPT 当前档案（ADR 0005）。
# lib/cmd-chatgpt.zsh 分派到 use 时 source 本文件并调用 _ccp_cmd_chatgpt_use。
#
# 切换逻辑只在这里实现一份：App 点击 ChatGPT 档案时也是在后台执行本命令，
# App 启动时执行 `ccp chatgpt use <当前档案>` 恢复重启后丢失的 launchd 环境变量（本命令是幂等的）。
#
# 依次：
#   1. 检查名字（规则与 ccp use 相同）；不合规、是保留名、档案不存在时报错，什么都不改，返回 1。
#   2. 写当前档案记录 ~/.codex-profiles/active（格式、原子写入方式与 ccp use 相同；default 也写入）。
#   3. launchctl setenv CODEX_HOME <档案目录>（default 时 launchctl unsetenv CODEX_HOME）：之后经 LaunchServices
#      打开的 App（Dock、Spotlight、open、Zed 等）使用新档案。失败时报错返回 1（记录已经改了，codex 包装函数照样跟随）。
#   4. ChatGPT 桌面 App（bundle com.openai.codex）正在运行时只提示"退出并重新打开后才使用新档案"：
#      只做切换，不替用户退出或重新打开桌面 App（正在进行的任务由用户自己决定什么时候中断）。
#
# 外部程序 launchctl、osascript 都按 PATH 查找（测试在 PATH 最前面放假程序，见 tests/fakes/）。

_ccp_cmd_chatgpt_use() {
  emulate -L zsh
  local name= arg
  integer count=0
  for arg in "$@"; do
    case $arg in
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
      _ccp_chatgpt_print_case_hint "$name"
      print -u2 -r -- "  用 \`ccp chatgpt ls\` 查看已有档案，或用 \`ccp chatgpt add $name\` 新建档案。"
      return 1
    fi
  fi

  _ccp_write_active_in "$(_ccp_chatgpt_profiles_root)" "$name" "ccp chatgpt use" || return 1

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

  if _ccp_chatgpt_app_running; then
    print -r -- "ChatGPT 正在运行：你自己退出并重新打开它之后，它才会使用新档案。"
  fi
  return 0
}

# ChatGPT 桌面 App 是否正在运行。查询本身不需要自动化授权；查询失败（例如没装 ChatGPT）按没在运行处理。
_ccp_chatgpt_app_running() {
  emulate -L zsh
  [[ $(osascript -e 'application id "com.openai.codex" is running' 2>/dev/null) == true ]]
}
