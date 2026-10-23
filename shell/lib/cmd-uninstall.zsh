# ccp uninstall [--yes]：移除 zsh 接入。bin/ccp 分派到 uninstall 时 source 本文件并调用 _ccp_cmd_uninstall。
# 参数：ccp uninstall 之后的全部参数；返回值即 ccp 的退出码。
#
# 从 ~/.zshrc 删除所有与接入行（见 lib/zshrc.zsh）完全相同的整行，连同各自结尾的换行；
# 其余字节原样保留。不询问；--yes / -y 可以写，没有作用（与 init 对称，方便 App 调用）。
#   - ~/.zshrc 不存在或没有接入行：什么都不改（不重写文件），返回 0。
#   - 删除后文件为空也保留这个空文件，不删除用户的文件。
#   - 是软链接时改写它指向的文件，软链接本身不变；保留原文件的权限。
#   - 写入是原子的：在同一目录下写临时文件，再 rename 覆盖。
#   - 已知差异：接入前最后一行没有换行时，init 为了让接入行单独成行补上的那个换行，卸载后保留。

_ccp_cmd_uninstall() {
  emulate -L zsh
  local arg
  for arg in "$@"; do
    case $arg in
      (--yes|-y) ;;
      (*)
        print -u2 -r -- "ccp uninstall: 不认识的参数 \"$arg\""
        print -u2
        _ccp_usage >&2
        return 2
        ;;
    esac
  done

  local zshrc target line content= l mode tmp
  local -a lines kept
  zshrc=$(_ccp_zshrc_path)
  line=$(_ccp_zshrc_line)
  target=${zshrc:A}

  if [[ ! -e $target ]]; then
    print -r -- "没有 $zshrc，无需卸载。"
    return 0
  fi
  if ! _ccp_read_exact "$target" content; then
    print -u2 -r -- "ccp uninstall: 无法读取 $zshrc。"
    return 1
  fi

  lines=("${(@ps:\n:)content}")
  for l in "${lines[@]}"; do
    [[ $l == "$line" ]] || kept+=("$l")
  done
  if (( ${#kept} == ${#lines} )); then
    print -r -- "$zshrc 里没有 ccp init 添加的接入行，无需卸载。"
    return 0
  fi

  # 最后一行恰好是接入行且没有结尾换行时，kept 的末尾不再是空元素，拼接后也就去掉了它前面的换行
  mode=$(/usr/bin/stat -f %Lp -- "$target") || mode=
  if ! tmp=$(/usr/bin/mktemp "${target:h}/.zshrc.ccp-uninstall.XXXXXX"); then
    print -u2 -r -- "ccp uninstall: 无法在 ${target:h} 里创建临时文件，$zshrc 保持不变。"
    return 1
  fi
  if ! print -rn -- "${(pj:\n:)kept}" > "$tmp" \
      || { [[ -n $mode ]] && ! /bin/chmod -- "$mode" "$tmp" } \
      || ! /bin/mv -f -- "$tmp" "$target"; then
    /bin/rm -f -- "$tmp"
    print -u2 -r -- "ccp uninstall: 写入 $zshrc 失败，文件保持不变。"
    return 1
  fi
  print -r -- "已从 $zshrc 删除接入行。新开的终端里不再加载 cc-pilot；当前终端里已加载的 claude 函数在关闭后消失。"
}
