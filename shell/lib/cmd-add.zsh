# ccp add（由 ticket 03 实现）。bin/ccp 分派到 add 时 source 本文件并调用 _ccp_cmd_add。
# 参数：ccp add 之后的全部参数；返回值即 ccp 的退出码。

_ccp_cmd_add() {
  emulate -L zsh
  print -u2 -r -- "ccp add: 尚未实现"
  return 1
}
