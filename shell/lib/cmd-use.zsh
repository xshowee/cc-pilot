# ccp use（由 ticket 02 实现）。bin/ccp 分派到 use 时 source 本文件并调用 _ccp_cmd_use。
# 参数：ccp use 之后的全部参数；返回值即 ccp 的退出码。

_ccp_cmd_use() {
  emulate -L zsh
  print -u2 -r -- "ccp use: 尚未实现"
  return 1
}
