# cc-pilot 共享库：档案目录、当前档案记录、档案名规则、档案解析。
#
# 被 cc-pilot.zsh（source 进用户的交互 shell）和 bin/ccp 共同 source。
# 因为会进入用户的交互 shell：只定义 _ccp_ 开头的函数，不定义全局变量；
# 每个函数开头 `emulate -L zsh`，不受用户 setopt 的影响，也不改动用户的选项；
# 出错时只 return，绝不 exit（exit 会关掉用户的终端）。
#
# 约定（spec "磁盘上的文件约定"）：
#   默认档案      ~/.claude（不设置 CLAUDE_CONFIG_DIR）
#   其他档案      ~/.claude-profiles/<名字>/
#   当前档案记录  ~/.claude-profiles/active，一行，档案名；不存在、为空或为 default 表示默认档案
#   档案名规则    ^[A-Za-z0-9][A-Za-z0-9._-]*$，default 是保留名

# 输出档案根目录的绝对路径：$HOME/.claude-profiles（去掉 HOME 结尾的 /）
_ccp_profiles_root() {
  emulate -L zsh
  setopt extended_glob
  print -r -- "${HOME%%/##}/.claude-profiles"
}

# 输出当前档案记录文件的路径
_ccp_active_file() {
  emulate -L zsh
  print -r -- "$(_ccp_profiles_root)/active"
}

# 档案名是否符合规则（不检查是否存在；default 也算合规）
_ccp_valid_name() {
  emulate -L zsh
  setopt extended_glob
  [[ $1 == [A-Za-z0-9][A-Za-z0-9._-]# ]]
}

# 输出某个非默认档案的配置目录：$HOME/.claude-profiles/<名字>
# 这个字符串就是传给 CLAUDE_CONFIG_DIR、并用来计算钥匙串 service 名的值：
# 绝对路径，不含 ~，结尾不带 /。
_ccp_profile_dir() {
  emulate -L zsh
  print -r -- "$(_ccp_profiles_root)/$1"
}

# 输出当前档案记录中的档案名；记录不存在、不可读或为空时输出 default。
# 只取第一行，去掉首尾空白（含 \r）。不校验名字是否合规。
_ccp_active_name() {
  emulate -L zsh
  setopt extended_glob
  local f line=
  f=$(_ccp_active_file)
  # 注意：$(<file) 在文件不存在时会往 stderr 报错，2>/dev/null 也拦不住，所以先判断
  if [[ -f $f && -r $f ]]; then
    IFS= read -r line < $f
  fi
  line=${${line##[[:space:]]#}%%[[:space:]]#}
  print -r -- "${line:-default}"
}

# 解析本次会话要用的档案（不考虑 CLAUDE_CONFIG_DIR，那由调用方先判断）：
#   CLAUDE_PROFILE 非空时用它，否则用当前档案记录。
# 输出：默认档案时什么都不输出；其他档案输出它的配置目录。
# 名字不合规或档案不存在时，往 stderr 输出错误和修复建议，返回 1。
_ccp_resolve_config_dir() {
  emulate -L zsh
  local name origin dir source_kind
  if [[ -n ${CLAUDE_PROFILE-} ]]; then
    name=$CLAUDE_PROFILE
    source_kind=env
    origin="CLAUDE_PROFILE 指定的"
  else
    name=$(_ccp_active_name)
    source_kind=active
    origin="当前"
  fi

  [[ $name == default ]] && return 0

  if ! _ccp_valid_name "$name"; then
    print -u2 -r -- "cc-pilot: ${origin}档案名 \"$name\" 不合规（只能包含字母、数字、. _ -，且以字母或数字开头）。"
    _ccp_print_fix_hint $source_kind
    return 1
  fi

  dir=$(_ccp_profile_dir "$name")
  if [[ ! -d $dir ]]; then
    print -u2 -r -- "cc-pilot: ${origin}档案 \"$name\" 不存在（$dir）。"
    _ccp_print_fix_hint $source_kind
    return 1
  fi
  print -r -- "$dir"
}

# 输出修复建议（解析失败时用）。参数：env（来自 CLAUDE_PROFILE）或 active（来自当前档案记录）
_ccp_print_fix_hint() {
  emulate -L zsh
  if [[ $1 == env ]]; then
    print -u2 -r -- "  修复：执行 \`unset CLAUDE_PROFILE\` 改用当前档案，或用 \`ccp ls\` 查看已有档案、\`ccp add <名字>\` 新建档案。"
  else
    print -u2 -r -- "  修复：执行 \`ccp use default\` 切回默认档案，或用 \`ccp ls\` 查看已有档案、\`ccp add <名字>\` 新建档案。"
  fi
}
