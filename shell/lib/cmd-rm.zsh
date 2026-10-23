# ccp rm（由 ticket 04 实现）。bin/ccp 分派到 rm 时 source 本文件并调用 _ccp_cmd_rm。
# 参数：ccp rm 之后的全部参数；返回值即 ccp 的退出码。

_ccp_cmd_rm() {
  emulate -L zsh
  print -u2 -r -- "ccp rm: 尚未实现"
  return 1
}
