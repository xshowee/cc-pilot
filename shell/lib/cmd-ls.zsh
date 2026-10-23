# ccp ls：列出所有档案并标出当前档案。bin/ccp 分派到 ls 时 source 本文件并调用 _ccp_cmd_ls。
# 参数：ccp ls 之后的全部参数；返回值即 ccp 的退出码。
#
# 输出每行一个档案："* 名字"是当前档案，"  名字"是其他档案。第一行总是 default，
# 其余是 ~/.claude-profiles/ 下名字合规（不含保留名）的目录（包括指向目录的软链接），按字节序排列。
# 只显示名字，不读取也不显示任何账号信息。
# 当前档案记录指向的档案无法使用时，照常列出其他档案，并在 stderr 给出提示（退出码仍为 0）。

_ccp_cmd_ls() {
  emulate -L zsh
  if (( $# )); then
    print -u2 -r -- "ccp ls: 不接受参数"
    print -u2
    _ccp_usage >&2
    return 2
  fi

  local current entry name
  local -a names
  current=$(_ccp_active_name)
  local LC_COLLATE=C  # 按字节序排列，不受用户 locale 影响
  for entry in "$(_ccp_profiles_root)"/*(N-/on); do
    name=${entry:t}
    _ccp_valid_name "$name" && ! _ccp_reserved_name "$name" && names+=("$name")
  done

  for name in default $names; do
    if [[ $name == "$current" ]]; then
      print -r -- "* $name"
    else
      print -r -- "  $name"
    fi
  done

  if [[ $current != default ]] && (( ! ${names[(Ie)$current]} )); then
    local CLAUDE_PROFILE=
    _ccp_resolve_config_dir > /dev/null
  fi
  return 0
}
