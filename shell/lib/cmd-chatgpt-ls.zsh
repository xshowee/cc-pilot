# ccp chatgpt ls（别名 ccp codex ls）：列出所有 ChatGPT 档案并标出当前档案。
# lib/cmd-chatgpt.zsh 分派到 ls 时 source 本文件并调用 _ccp_cmd_chatgpt_ls。
#
# 输出格式与 ccp ls 相同：每行一个档案，"* 名字"是当前档案，"  名字"是其他档案。第一行总是 default
# （即 ~/.codex，不论它是否存在），其余是 ~/.codex-profiles/ 下名字合规（不含保留名）的目录
# （包括指向目录的软链接），按字节序排列。只显示名字，不读取 auth.json，不显示任何账号信息。
# 当前档案记录指向的档案无法使用时，照常列出，并在 stderr 给出提示（退出码仍为 0）。

_ccp_cmd_chatgpt_ls() {
  emulate -L zsh
  if (( $# )); then
    print -u2 -r -- "ccp chatgpt ls: 不接受参数"
    print -u2
    _ccp_chatgpt_usage >&2
    return 2
  fi

  local current name
  local -a reply names
  current=$(_ccp_chatgpt_active_name)
  _ccp_chatgpt_profile_names
  names=("${reply[@]}")

  for name in default $names; do
    if [[ $name == "$current" ]]; then
      print -r -- "* $name"
    else
      print -r -- "  $name"
    fi
  done

  if [[ $current != default ]] && (( ! ${names[(Ie)$current]} )); then
    local CODEX_PROFILE=
    _ccp_chatgpt_resolve_home > /dev/null
  fi
  return 0
}
