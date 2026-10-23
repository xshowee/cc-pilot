# ccp current：输出当前档案的名字。bin/ccp 分派到 current 时 source 本文件并调用 _ccp_cmd_current。
# 参数：ccp current 之后的全部参数；返回值即 ccp 的退出码。
#
# stdout 只有一行档案名（当前档案记录不存在、为空或为 default 时输出 default），方便脚本和提示符使用。
# 只看当前档案记录，不看 CLAUDE_PROFILE（终端覆盖不改变当前档案）。
# 记录里的档案无法使用（名字不合规、是保留名或档案目录不存在）时，仍输出记录里的名字，
# 另外在 stderr 输出错误和修复建议，返回 1。

_ccp_cmd_current() {
  emulate -L zsh
  if (( $# )); then
    print -u2 -r -- "ccp current: 不接受参数"
    print -u2
    _ccp_usage >&2
    return 2
  fi
  print -r -- "$(_ccp_active_name)"
  # 屏蔽 CLAUDE_PROFILE，只检查当前档案记录能否解析
  local CLAUDE_PROFILE=
  _ccp_resolve_config_dir > /dev/null
}
