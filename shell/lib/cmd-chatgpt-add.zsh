# ccp chatgpt add <名字>（别名 ccp codex add）：新建 ChatGPT 档案，布置共享资源，然后直接进入它的 codex login。
# lib/cmd-chatgpt.zsh 分派到 add 时 source 本文件并调用 _ccp_cmd_chatgpt_add；返回值即 ccp 的退出码。
#
# 新档案 ~/.codex-profiles/<名字>/ 里只有（ADR 0006）：
#   config.toml   默认档案 config.toml 的副本（没有则新建），顶层写入 sqlite_home = "<~/.codex 的绝对路径>"，
#                 让会话数据库落在 ~/.codex（各档案共享会话）；之后各档案各改各的（不同套餐可用不同模型）
#   共享资源      指向 ~/.codex 下同名项的软链接，清单见 lib/chatgpt-profiles.zsh 的 _ccp_chatgpt_share_resources
# 不创建、不复制 auth.json、installation_id、.codex-global-state.json、history.jsonl（每个档案一份，由
# codex / 桌面 App 自己生成）。不修改 ChatGPT 当前档案记录。
#
# 登录：ccp 是独立脚本，没有 codex 包装函数，直接 `CODEX_HOME=<档案目录> command codex login`（codex 经 PATH 查找，
# 测试里是 tests/fakes/codex）。登录没完成时保留档案，提示之后怎么在这个档案里登录，退出码非零。

_ccp_cmd_chatgpt_add() {
  emulate -L zsh
  if (( $# != 1 )); then
    print -u2 -r -- "用法：ccp chatgpt add <名字>"
    return 2
  fi
  local name=$1 root dir

  # 先做完全部检查，再动磁盘：任何一项不通过都不创建、不修改任何文件（规则同 ccp add）
  if ! _ccp_valid_name "$name"; then
    print -u2 -r -- "ccp chatgpt add: 档案名 \"$name\" 不合规（只能包含字母、数字、. _ -，且以字母或数字开头）。"
    return 1
  fi
  if _ccp_reserved_name "$name"; then
    print -u2 -r -- "ccp chatgpt add: \"$name\" 是保留名，不能用作档案名。"
    return 1
  fi
  root=$(_ccp_chatgpt_profiles_root)
  dir=$(_ccp_chatgpt_profile_dir "$name")
  # 任何类型的同名项都算已存在（普通文件、悬空的软链接也算）；文件系统不分大小写时只差大小写的也算
  if [[ -e $dir || -L $dir ]]; then
    print -u2 -r -- "ccp chatgpt add: 档案 \"$name\" 已存在（$dir）。用 \`ccp chatgpt ls\` 查看已有档案。"
    return 1
  fi

  # 只创建档案目录本身（不带 -p），即使有人同时创建了同名档案也不会混用
  /bin/mkdir -p -- "$root" && /bin/mkdir -- "$dir" || {
    print -u2 -r -- "ccp chatgpt add: 无法创建档案目录 $dir"
    return 1
  }
  if ! _ccp_chatgpt_share_resources "$dir"; then
    print -u2 -r -- "ccp chatgpt add: 无法建立共享资源的软链接，已撤销创建。"
    /bin/rm -rf -- "$dir"
    return 1
  fi
  if ! _ccp_chatgpt_seed_config_toml "$dir"; then
    print -u2 -r -- "ccp chatgpt add: 无法写入 $dir/config.toml，已撤销创建。"
    /bin/rm -rf -- "$dir"
    return 1
  fi

  print -r -- "已创建 ChatGPT 档案 \"$name\"（$dir）。"
  print -r -- "正在这个档案里运行 codex login，请完成登录。"
  local rc
  CODEX_HOME=$dir command codex login
  rc=$?
  if (( rc == 0 )) && [[ -e $dir/auth.json ]]; then
    return 0
  fi
  if (( rc == 127 )) && (( ! $+commands[codex] )); then
    print -u2 -r -- "ccp chatgpt add: 没有找到 codex 命令，请先安装 Codex CLI。"
  fi
  print -u2 -r -- "ccp chatgpt add: 没有完成登录，档案 \"$name\" 已保留。之后可以在这个档案里登录："
  print -u2 -r -- "  CODEX_HOME=${(q-)dir} command codex login"
  (( rc == 0 )) && rc=1
  return rc
}

# ---------- config.toml ----------

# 写新档案的 config.toml：第一行是 sqlite_home = "<默认档案目录>"（TOML 基本字符串，转义 \ 和 "），
# 之后是默认档案 config.toml 的原样内容（是软链接时取它指向的内容），只去掉其中顶层（第一个 [表] 之前）
# 已有的 sqlite_home，避免重复的键。sqlite_home 必须是顶层键，所以写在第一行。
# 默认档案没有 config.toml 时只有这一行；有但读不出时也只写这一行，并往 stderr 提示。
# 先写临时文件再改名。参数：新档案目录。写入失败时返回 1。
_ccp_chatgpt_seed_config_toml() {
  emulate -L zsh
  local dst="$1/config.toml" tmp="$1/config.toml.ccp-tmp" src default value line
  default=$(_ccp_chatgpt_default_dir)
  src=$default/config.toml
  value=${default//\\/\\\\}
  value=${value//\"/\\\"}
  line="sqlite_home = \"$value\""

  if [[ -e $src || -L $src ]]; then
    if ! { print -r -- "$line" && /usr/bin/awk '
        BEGIN { top = 1 }
        # 表头：[名字] 或 [[名字]]，名字以裸键字符或引号开头，行尾只能跟注释
        /^[ \t]*\[\[?[ \t]*[A-Za-z0-9_"'\''-][^=]*\]\]?[ \t\r]*(#.*)?$/ { top = 0 }
        top && /^[ \t]*(sqlite_home|"sqlite_home"|'\''sqlite_home'\'')[ \t]*=/ { next }
        { print }' < "$src" } > "$tmp" 2>/dev/null; then
      print -u2 -r -- "ccp chatgpt add: 无法读取默认档案的 $src，新档案的 config.toml 只有 sqlite_home 一项。"
      print -r -- "$line" > "$tmp" || { /bin/rm -f -- "$tmp"; return 1 }
    fi
  else
    print -r -- "$line" > "$tmp" || { /bin/rm -f -- "$tmp"; return 1 }
  fi
  /bin/mv -f -- "$tmp" "$dst" && return 0
  /bin/rm -f -- "$tmp"
  return 1
}
