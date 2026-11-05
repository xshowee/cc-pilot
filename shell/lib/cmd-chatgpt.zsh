# ccp chatgpt <子命令>（别名 ccp codex）：ChatGPT 档案的命令。bin/ccp 分派到 chatgpt / codex 时
# source 本文件并调用 _ccp_cmd_chatgpt。参数：ccp chatgpt 之后的全部参数；返回值即 ccp 的退出码。
#
# 这里只负责第二级分派：子命令 <sub> 的实现放在它自己的文件 lib/cmd-chatgpt-<sub>.zsh 里，
# 定义 _ccp_cmd_chatgpt_<sub>（文件名以 cmd- 开头，bin/ccp 不会把它当共享库自动 source）。
# 新增子命令：新增该文件，在下面的 case 和 _ccp_chatgpt_usage 里各加一行。

_ccp_chatgpt_usage() {
  print -r -- "用法：ccp chatgpt <命令> [参数]（ccp codex 与之相同）

命令：
  ls              列出所有 ChatGPT 档案，并标出当前档案
  use <名字>      切换当前档案（default 表示默认档案）；不会退出或重新打开 ChatGPT 桌面 App，
                  它正在运行时由你自己退出并重新打开
  add <名字>      新建 ChatGPT 档案（共享会话、技能等），并在其中运行 codex login
  rm <名字>       删除 ChatGPT 档案：确认后先停止它的守护进程、执行 codex logout，确认已登出才删除

单个终端临时使用其他档案：CODEX_PROFILE=<名字> codex"
}

_ccp_cmd_chatgpt() {
  emulate -L zsh
  case ${1-} in
    (ls|use|add|rm)
      source $_ccp_lib/cmd-chatgpt-$1.zsh || return 1
      _ccp_cmd_chatgpt_$1 "${@:2}"
      ;;
    (help|-h|--help)
      _ccp_chatgpt_usage
      return 0
      ;;
    ('')
      _ccp_chatgpt_usage >&2
      return 2
      ;;
    (*)
      print -u2 -r -- "ccp chatgpt: 未知命令 \"$1\""
      print -u2
      _ccp_chatgpt_usage >&2
      return 2
      ;;
  esac
}
