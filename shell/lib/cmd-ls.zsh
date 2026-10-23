# ccp ls（由 ticket 02 实现）。bin/ccp 分派到 ls 时 source 本文件并调用 _ccp_cmd_ls。
# 参数：ccp ls 之后的全部参数；返回值即 ccp 的退出码。

_ccp_cmd_ls() {
  emulate -L zsh
  print -u2 -r -- "ccp ls: 尚未实现"
  return 1
}
