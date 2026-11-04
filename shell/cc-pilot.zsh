# cc-pilot 的 zsh 入口。由 ~/.zshrc 里的一行 source 加载（安装后位于 ~/.cc-pilot/cc-pilot.zsh）：
#   source "$HOME/.cc-pilot/cc-pilot.zsh"
#
# 它做三件事：
#   1. 把本文件所在目录下的 bin/（安装后即 ~/.cc-pilot/bin）加到 PATH 最前面（已存在则不重复加）；
#   2. 定义 claude 包装函数，在启动 Claude Code 时决定用哪个档案；
#   3. 定义 codex 包装函数，在启动 codex（ChatGPT 的命令行）时决定用哪个 ChatGPT 档案。
# 本文件被 source 进用户的交互 shell：除了 claude、codex 函数和 _ccp_ 开头的私有函数，不留下任何东西。

() {
  emulate -L zsh
  local root=${${(%):-%x}:a:h}
  source "$root/lib/profiles.zsh" || return 1
  source "$root/lib/chatgpt-profiles.zsh" || return 1
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

# codex 包装函数（ADR 0005）。ChatGPT 档案的决定顺序（从高到低）：
#   1. CODEX_PROFILE 非空：使用它指定的档案（为空视同未设置），不管环境里的 CODEX_HOME；
#   2. 环境里有用户直接指定的 CODEX_HOME（即使为空）：原样调用 codex，不做任何处理；
#   3. 否则使用当前 ChatGPT 档案记录（~/.codex-profiles/active）里的档案。
# CODEX_HOME 等于 ~/.codex 或位于 ~/.codex-profiles/ 之下时，视为 cc-pilot 设置的（多半是从 launchd 继承来的
# 旧值，例如从 Dock 打开的终端），不算用户直接指定，按第 3 条重设（_ccp_chatgpt_managed_home）。
# 解析出默认档案时去掉 CODEX_HOME（在子 shell 里 unset，用户 shell 里的变量不变；本来就没有时直接调用，
# 与没装 cc-pilot 完全一样）；其他档案只为这一次调用设置 CODEX_HOME=$HOME/.codex-profiles/<名字>，不 export。
# 档案不存在时报错并返回非零，不启动 codex，也不回退到默认档案。
# 用 `command codex` 调用 PATH 里真正的 codex，不会递归调用本函数；用 `function codex {` 的写法定义，
# 避免用户已有的同名 alias 在定义时被展开。
function codex {
  emulate -L zsh
  if [[ -z ${CODEX_PROFILE-} ]] && (( ${+CODEX_HOME} )) && ! _ccp_chatgpt_managed_home "$CODEX_HOME"; then
    command codex "$@"
    return
  fi
  local _ccp_home
  _ccp_home=$(_ccp_chatgpt_resolve_home) || return
  if [[ -n $_ccp_home ]]; then
    CODEX_HOME=$_ccp_home command codex "$@"
  elif (( ${+CODEX_HOME} )); then
    ( unset CODEX_HOME; command codex "$@" )
  else
    command codex "$@"
  fi
}
