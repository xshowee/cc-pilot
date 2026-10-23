# ccp use <名字>：切换当前档案。bin/ccp 分派到 use 时 source 本文件并调用 _ccp_cmd_use。
# 参数：ccp use 之后的全部参数；返回值即 ccp 的退出码。
#
# 写入格式（App 的"切换"必须与之完全相同）：当前档案记录 ~/.claude-profiles/active 的内容是
# 档案名加一个换行（UTF-8，无 BOM）；切回默认档案时写入 "default\n"，不删除记录文件。
# 原子写入：在同一目录下用 mktemp 建临时文件 .active.XXXXXX，写完后 rename 到 active。
# 名字不合规、是保留名、或者档案目录不存在时报错，返回 1，记录保持不变。

_ccp_cmd_use() {
  emulate -L zsh
  if (( $# != 1 )); then
    print -u2 -r -- "ccp use: 需要且只需要一个档案名"
    print -u2
    _ccp_usage >&2
    return 2
  fi

  local name=$1 root record dir tmp
  if [[ $name != default ]]; then
    if ! _ccp_valid_name "$name" || _ccp_reserved_name "$name"; then
      print -u2 -r -- "ccp use: 档案名 $(_ccp_invalid_name_reason "$name")。"
      return 1
    fi
    dir=$(_ccp_profile_dir "$name")
    if [[ ! -d $dir ]]; then
      print -u2 -r -- "ccp use: 档案 \"$name\" 不存在（$dir）。"
      print -u2 -r -- "  用 \`ccp ls\` 查看已有档案，或用 \`ccp add $name\` 新建档案。"
      return 1
    fi
  fi

  root=$(_ccp_profiles_root)
  record=$(_ccp_active_file)
  # rename 到一个目录（或指向目录的软链接）会把文件移进目录里，必须先拦住
  if [[ -d $record ]]; then
    print -u2 -r -- "ccp use: 当前档案记录的位置 $record 是一个目录，请先手动处理它。"
    return 1
  fi
  if ! /bin/mkdir -p -- "$root" || ! tmp=$(/usr/bin/mktemp "$root/.active.XXXXXX"); then
    print -u2 -r -- "ccp use: 无法在 $root 里写入当前档案记录。"
    return 1
  fi
  if ! print -r -- "$name" > "$tmp" || ! /bin/mv -f -- "$tmp" "$record"; then
    /bin/rm -f -- "$tmp"
    print -u2 -r -- "ccp use: 写入当前档案记录 $record 失败，记录保持不变。"
    return 1
  fi
  print -r -- "当前档案已切换为 $name。之后新启动的 claude 会使用它；已在运行的会话不受影响。"
}
