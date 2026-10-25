# ccp statusline <档案名>：状态栏转发命令（token-usage ticket 04，ADR 0004）。
#
# 不给用户直接用：claude 包装函数用 --settings 把会话的 statusLine.command 换成
# `<安装目录>/bin/ccp statusline <档案名>`。Claude Code 每次刷新状态栏时运行它（sh -c，
# 工作目录是会话的当前目录），把状态栏 JSON 从标准输入交给它。它做两件事：
#   1. 把这份 JSON 原样（不在 shell 里解析）加上档案名和时间，写进实时额度文件
#      ~/.claude-profiles/.live-quota/<档案名>.json，内容是
#        {"profile":"<档案名>","received_at":<Unix 秒，三位小数>,"status":<原始 stdin JSON>}
#      先写同目录里的临时文件 .<档案名>.json.<pid>，再 rename 原子替换。由 App 读取和解析。
#   2. 找出原本生效的状态栏命令，把标准输入原样交给它（/bin/sh -c，~ 等写法照常展开），
#      原样输出它的标准输出，退出码也用它的；都没配时什么都不输出。
# 不能拖慢状态栏：写文件失败静默忽略，不联网；只用 zsh 内建和 /usr/bin/plutil。

# 原本生效的状态栏命令：--settings 的优先级高于项目设置，所以按 Claude Code 的优先级依次查
#   <project_dir>/.claude/settings.local.json、<project_dir>/.claude/settings.json、档案的 settings.json
# （project_dir 取状态栏 JSON 的 workspace.project_dir），取第一个有非空 statusLine.command 的。
# 每次运行都重新读，所以用户在会话里用 /statusline 改过的设置照常生效。
# 状态栏刷新得很勤，少起子进程：命令放进 REPLY 而不是输出，不含 statusLine 的设置文件不交给 plutil。
# 参数：档案名、状态栏 JSON。找到时把命令放进 REPLY；没有时返回 1。
_ccp_statusline_original() {
  emulate -L zsh
  zmodload zsh/mapfile 2>/dev/null
  local name=$1 input=$2 project config f cmd
  local -a files
  project=$(print -rn -- "$input" | /usr/bin/plutil -extract workspace.project_dir raw -o - - 2>/dev/null)
  [[ $project == /* ]] && files+=("$project/.claude/settings.local.json" "$project/.claude/settings.json")
  if [[ $name == default ]]; then
    config=$(_ccp_default_config_dir)
  else
    config=$(_ccp_profile_dir "$name")
  fi
  files+=("$config/settings.json")
  for f in $files; do
    [[ -f $f ]] || continue
    # 加载不了 zsh/mapfile 时不预筛，一律交给 plutil
    (( ${+mapfile} )) && [[ ${mapfile[$f]} != *statusLine* ]] && continue
    cmd=$(/usr/bin/plutil -extract statusLine.command raw -o - "$f" 2>/dev/null) || continue
    if [[ -n $cmd ]]; then
      REPLY=$cmd
      return 0
    fi
  done
  return 1
}

# 把状态栏 JSON 写进实时额度文件。标准输入不是 JSON 对象（为空等）时不写。
# 失败时只返回非零，调用方把 stderr 丢掉。参数：档案名、状态栏 JSON。
_ccp_statusline_write() {
  emulate -L zsh
  setopt extended_glob
  local name=$1 input=$2 dir tmp
  [[ $input == [[:space:]]#\{* ]] || return 0
  zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm || return 1
  zmodload zsh/datetime || return 1
  local -F 3 now=$EPOCHREALTIME
  dir=$(_ccp_live_quota_dir)
  zf_mkdir -p -- $dir || return 1
  tmp=$dir/.$name.json.$$
  if ! print -rn -- "{\"profile\":\"$name\",\"received_at\":$now,\"status\":$input}" >| $tmp; then
    zf_rm -f -- $tmp
    return 1
  fi
  zf_mv -f -- $tmp $dir/$name.json || { zf_rm -f -- $tmp; return 1 }
}

_ccp_cmd_statusline() {
  emulate -L zsh
  local name=${1-} input= REPLY
  # 读到 EOF，原样保留（含结尾的换行；$(cat) 会去掉它们）
  IFS= read -r -d '' input
  # 原状态栏命令又调用了转发命令（例如用户手动把它写进了设置）：什么都不做，避免无限递归
  [[ -n ${_CCP_STATUSLINE_FORWARDING-} ]] && return 0
  if [[ $name != default ]] && { ! _ccp_valid_name "$name" || _ccp_reserved_name "$name" }; then
    return 0
  fi
  _ccp_statusline_write "$name" "$input" 2>/dev/null
  _ccp_statusline_original "$name" "$input" || return 0
  print -rn -- "$input" | _CCP_STATUSLINE_FORWARDING=1 /bin/sh -c "$REPLY"
}
