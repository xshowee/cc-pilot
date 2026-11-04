# cc-pilot 共享库（ChatGPT 工具）：ChatGPT 档案目录、当前档案记录、档案解析（ADR 0005）。
#
# 与 profiles.zsh（Claude Code 一侧）并列，规则相同：只定义 _ccp_ 开头的函数，不定义全局变量；
# 每个函数开头 `emulate -L zsh`；出错时只 return，绝不 exit。
# bin/ccp 自动 source lib/ 下所有不以 cmd- 开头的文件，所以 ccp 的子命令里可以直接用这里的函数；
# 交互 shell 的入口 cc-pilot.zsh 目前只 source profiles.zsh（codex 包装函数加入时再 source 本文件）。
#
# 约定（spec "工具维度"）：
#   默认档案      ~/.codex（不设置 CODEX_HOME）
#   其他档案      ~/.codex-profiles/<名字>/，即该档案的 CODEX_HOME
#   当前档案记录  ~/.codex-profiles/active，格式同 Claude 一侧：一行档案名；不存在、为空或为 default 表示默认档案
#   档案名规则    与 Claude 一侧相同（_ccp_valid_name、_ccp_reserved_name，default 和 active 是保留名）

# 输出 ChatGPT 档案根目录：$HOME/.codex-profiles（去掉 HOME 结尾的 /）
_ccp_chatgpt_profiles_root() {
  emulate -L zsh
  setopt extended_glob
  print -r -- "${HOME%%/##}/.codex-profiles"
}

# 输出 ChatGPT 当前档案记录文件的路径
_ccp_chatgpt_active_file() {
  emulate -L zsh
  print -r -- "$(_ccp_chatgpt_profiles_root)/active"
}

# 输出 ChatGPT 默认档案的目录：$HOME/.codex。
# 启动默认档案时不设置 CODEX_HOME（codex 自己默认用它），这里只用于定位其中的文件。
_ccp_chatgpt_default_dir() {
  emulate -L zsh
  setopt extended_glob
  print -r -- "${HOME%%/##}/.codex"
}

# 输出某个非默认 ChatGPT 档案的目录（即它的 CODEX_HOME）：$HOME/.codex-profiles/<名字>
_ccp_chatgpt_profile_dir() {
  emulate -L zsh
  print -r -- "$(_ccp_chatgpt_profiles_root)/$1"
}

# 名为 $1 的 ChatGPT 档案目录是否存在：名字与 ~/.codex-profiles/ 下某个目录（或指向目录的软链接）
# 逐字节相同（理由同 _ccp_profile_exists：文件系统不分大小写）。不检查名字规则。
_ccp_chatgpt_profile_exists() {
  emulate -L zsh
  local -a names
  names=("$(_ccp_chatgpt_profiles_root)"/*(N-/:t))
  (( ${names[(Ie)$1]} ))
}

# 与 $1 只差大小写的已有 ChatGPT 档案名；没有时什么都不输出
_ccp_chatgpt_profile_case_variant() {
  emulate -L zsh
  local -a names
  names=("$(_ccp_chatgpt_profiles_root)"/*(N-/:t))
  local n
  for n in $names; do
    [[ ${(L)n} == ${(L)1} && $n != "$1" ]] && { print -r -- "$n"; return 0 }
  done
  return 0
}

# ~/.codex-profiles/ 下的 ChatGPT 档案名（不含 default），按字节序放进数组 reply：
# 名字合规、不是保留名的目录（包括指向目录的软链接）。与 ccp chatgpt ls、App 的列表一致。
_ccp_chatgpt_profile_names() {
  emulate -L zsh
  setopt extended_glob
  local entry name
  local LC_COLLATE=C  # 按字节序排列，不受用户 locale 影响
  reply=()
  for entry in "$(_ccp_chatgpt_profiles_root)"/*(N-/on); do
    name=${entry:t}
    _ccp_valid_name "$name" && ! _ccp_reserved_name "$name" && reply+=("$name")
  done
}

# 输出 ChatGPT 当前档案记录中的档案名；记录不存在、不可读或为空时输出 default。
# 读法与 _ccp_active_name 相同：只取第一行，去掉首尾空白（含 \r）；不校验名字。
_ccp_chatgpt_active_name() {
  emulate -L zsh
  setopt extended_glob
  local f line=
  f=$(_ccp_chatgpt_active_file)
  if [[ -f $f && -r $f ]]; then
    IFS= read -r line < $f
  fi
  line=${${line##[[:space:]]#}%%[[:space:]]#}
  print -r -- "${line:-default}"
}

# 解析本次要用的 ChatGPT 档案：CODEX_PROFILE 非空时用它，否则用当前档案记录。
# （不考虑用户直接指定的 CODEX_HOME，那由调用方先判断，见 ADR 0005。）
# 输出：默认档案时什么都不输出；其他档案输出它的目录（CODEX_HOME 的值）。
# 名字不合规或档案不存在时，往 stderr 输出错误和修复建议，返回 1。
_ccp_chatgpt_resolve_home() {
  emulate -L zsh
  local name origin dir source_kind variant
  if [[ -n ${CODEX_PROFILE-} ]]; then
    name=$CODEX_PROFILE
    source_kind=env
    origin="CODEX_PROFILE 指定的 ChatGPT "
  else
    name=$(_ccp_chatgpt_active_name)
    source_kind=active
    origin="当前 ChatGPT "
  fi

  [[ $name == default ]] && return 0

  if ! _ccp_valid_name "$name" || _ccp_reserved_name "$name"; then
    print -u2 -r -- "cc-pilot: ${origin}档案名 $(_ccp_invalid_name_reason "$name")。"
    _ccp_chatgpt_print_fix_hint $source_kind
    return 1
  fi

  dir=$(_ccp_chatgpt_profile_dir "$name")
  if ! _ccp_chatgpt_profile_exists "$name"; then
    print -u2 -r -- "cc-pilot: ${origin}档案 \"$name\" 不存在（$dir）。"
    variant=$(_ccp_chatgpt_profile_case_variant "$name")
    [[ -n $variant ]] && print -u2 -r -- "  档案名区分大小写：已有的档案是 \"$variant\"。"
    _ccp_chatgpt_print_fix_hint $source_kind
    return 1
  fi
  print -r -- "$dir"
}

# 输出修复建议（解析失败时用）。参数：env（来自 CODEX_PROFILE）或 active（来自当前档案记录）
_ccp_chatgpt_print_fix_hint() {
  emulate -L zsh
  if [[ $1 == env ]]; then
    print -u2 -r -- "  修复：执行 \`unset CODEX_PROFILE\` 改用当前档案，或用 \`ccp chatgpt ls\` 查看已有档案、\`ccp chatgpt add <名字>\` 新建档案。"
  else
    print -u2 -r -- "  修复：执行 \`ccp chatgpt use default\` 切回默认档案，或用 \`ccp chatgpt ls\` 查看已有档案、\`ccp chatgpt add <名字>\` 新建档案。"
  fi
}
