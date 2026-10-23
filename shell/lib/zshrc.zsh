# cc-pilot 共享库：~/.zshrc 的接入行（供 ccp init / ccp uninstall 使用）。
#
# 只被 bin/ccp source，不进入用户的交互 shell；约定同 profiles.zsh（_ccp_ 前缀、emulate -L zsh、只 return）。
#
# 接入就是在 ~/.zshrc 末尾追加下面这一行（$HOME 原样写入，不展开）：
#   source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot
# 判断"是否已接入"和卸载时，都只认与它完全相同的整行（不忽略空白，不认注释掉的或改过的行）。
# App 安装器应直接执行 `ccp init --yes` / `ccp uninstall`，而不是自己改 ~/.zshrc。

# 输出接入行（不带换行）
_ccp_zshrc_line() {
  emulate -L zsh
  print -rn -- 'source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot'
}

# 输出 ~/.zshrc 的路径（固定为 $HOME/.zshrc，不考虑 ZDOTDIR）
_ccp_zshrc_path() {
  emulate -L zsh
  setopt extended_glob
  print -r -- "${HOME%%/##}/.zshrc"
}

# 输出接入行要加载的入口文件的路径
_ccp_entry_path() {
  emulate -L zsh
  setopt extended_glob
  print -r -- "${HOME%%/##}/.cc-pilot/cc-pilot.zsh"
}

# _ccp_read_exact 文件 变量名：把文件的全部字节（包括结尾的换行）原样读进变量
_ccp_read_exact() {
  emulate -L zsh
  local _ccp_content
  # $(...) 会去掉结尾的换行，所以先多输出一个 x 再去掉
  _ccp_content=$(/bin/cat -- "$1" && print -rn x) || return 1
  : ${(P)2::=${_ccp_content%x}}
}

# _ccp_has_line 内容 行：内容里是否有与"行"完全相同的一整行
_ccp_has_line() {
  emulate -L zsh
  local -a lines
  lines=("${(@ps:\n:)1}")
  (( ${lines[(Ie)$2]} ))
}
