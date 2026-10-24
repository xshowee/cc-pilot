# cc-pilot 的 zsh 入口。由 ~/.zshrc 里的一行 source 加载（安装后位于 ~/.cc-pilot/cc-pilot.zsh）：
#   source "$HOME/.cc-pilot/cc-pilot.zsh"
#
# 它做两件事：
#   1. 把本文件所在目录下的 bin/（安装后即 ~/.cc-pilot/bin）加到 PATH 最前面（已存在则不重复加）；
#   2. 定义 claude 包装函数，在启动 Claude Code 时决定用哪个档案。
# 本文件被 source 进用户的交互 shell：除了 claude 函数和 _ccp_ 开头的私有函数，不留下任何东西。

() {
  emulate -L zsh
  local root=${${(%):-%x}:a:h}
  source "$root/lib/profiles.zsh" || return 1
  path=("$root/bin" "${(@)path:#$root/bin}")
}

# claude 包装函数。档案的决定顺序（从高到低）：
#   1. 环境里已经设置了 CLAUDE_CONFIG_DIR（即使为空）：原样调用 Claude Code，不做任何处理；
#   2. CLAUDE_PROFILE 非空：使用它指定的档案（为空视同未设置）；
#   3. 否则使用当前档案记录（~/.claude-profiles/active）里的档案。
# 解析出默认档案时不设置 CLAUDE_CONFIG_DIR；其他档案只为这一次调用设置
# CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/<名字>，不 export 到用户的 shell。
# 档案不存在时报错并返回非零，不回退到默认档案。
# 实时额度开启时（默认），还在用户参数前面加 --settings 覆盖，把状态栏换成 ccp statusline <档案名>
# （默认档案也加；用户自己传了 --settings 时不加），见 _ccp_statusline_override 和 ADR 0004。
# 用 `command claude` 调用 PATH 里真正的 Claude Code，不会递归调用本函数。
# 用 `function claude {` 的写法定义，避免用户已有的同名 alias 在定义时被展开。
function claude {
  emulate -L zsh
  if (( ${+CLAUDE_CONFIG_DIR} )); then
    command claude "$@"
    return
  fi
  local _ccp_dir
  _ccp_dir=$(_ccp_resolve_config_dir) || return
  # ccp 与本文件在同一个安装目录里（安装后是 ~/.cc-pilot/bin/ccp）
  local -a reply
  _ccp_statusline_override "${${_ccp_dir:t}:-default}" \
    "${${functions_source[claude]:-$HOME/.cc-pilot/cc-pilot.zsh}:a:h}/bin/ccp" "$@"
  if [[ -z $_ccp_dir ]]; then
    command claude "${reply[@]}" "$@"
  else
    CLAUDE_CONFIG_DIR=$_ccp_dir command claude "${reply[@]}" "$@"
  fi
}
