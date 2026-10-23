# ccp init [--yes]：接入 zsh。bin/ccp 分派到 init 时 source 本文件并调用 _ccp_cmd_init。
# 参数：ccp init 之后的全部参数；返回值即 ccp 的退出码。
#
# 在 ~/.zshrc 末尾追加接入行（见 lib/zshrc.zsh），之后新开的 zsh 就会加载 claude 包装函数和 ccp。
#   - 追加前先列出这一行并询问；答案从标准输入读取，y 或 yes（不分大小写）才继续，
#     其他回答或标准输入为空都视为拒绝：不修改任何文件，返回 1。
#   - --yes / -y：不询问，直接接入（供 App 等非交互调用）。
#   - 已有完全相同的接入行时什么都不改，也不询问，返回 0。所以执行多次也只有一行。
#   - ~/.zshrc 不存在时新建；不以换行结尾时先补一个换行，让接入行单独成行；
#     是软链接时写入它指向的文件，软链接本身不变。
#   - ~/.cc-pilot/cc-pilot.zsh 不存在（还没安装）时报错，不修改任何文件。

_ccp_cmd_init() {
  emulate -L zsh
  setopt extended_glob
  local assume_yes=0 arg
  for arg in "$@"; do
    case $arg in
      (--yes|-y) assume_yes=1 ;;
      (*)
        print -u2 -r -- "ccp init: 不认识的参数 \"$arg\""
        print -u2
        _ccp_usage >&2
        return 2
        ;;
    esac
  done

  local zshrc target line entry content= answer
  zshrc=$(_ccp_zshrc_path)
  line=$(_ccp_zshrc_line)
  entry=$(_ccp_entry_path)

  if [[ ! -f $entry ]]; then
    print -u2 -r -- "ccp init: 找不到 $entry，cc-pilot 还没有安装到 ~/.cc-pilot/。"
    print -u2 -r -- "  请先安装（打开 CC Pilot App，或把仓库的 shell/ 目录复制为 ~/.cc-pilot/），再执行 ccp init。"
    return 1
  fi

  # 软链接写入它最终指向的文件（不存在的 ~/.zshrc 保持原路径，追加时新建）
  target=${zshrc:A}
  if [[ -e $target ]]; then
    if ! _ccp_read_exact "$target" content; then
      print -u2 -r -- "ccp init: 无法读取 $zshrc。"
      return 1
    fi
  fi

  if _ccp_has_line "$content" "$line"; then
    print -r -- "$zshrc 里已经有接入行，无需重复接入。"
    return 0
  fi

  if (( ! assume_yes )); then
    print -r -- "ccp init 将在 $zshrc 末尾添加下面这一行，让之后新开的 zsh 加载 cc-pilot 的 claude 包装函数和 ccp 命令："
    print
    print -r -- "  $line"
    print
    print -rn -- "以后可以用 ccp uninstall 删除这一行。是否继续？[y/N] "
    answer=
    read -r answer
    if [[ $answer != (#i)(y|yes) ]]; then
      print
      print -r -- "已取消，没有修改任何文件。"
      return 1
    fi
  fi

  local prefix=
  [[ -n $content && $content != *$'\n' ]] && prefix=$'\n'
  if ! print -r -- "$prefix$line" >> "$target"; then
    print -u2 -r -- "ccp init: 写入 $zshrc 失败。"
    return 1
  fi
  print -r -- "已在 $zshrc 末尾添加接入行。新开的终端即可生效，当前终端可执行：source ~/.zshrc"
}
