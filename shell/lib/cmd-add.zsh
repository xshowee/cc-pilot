# ccp add <名字>：新建档案，并直接进入它的 Claude Code 完成首次引导和登录。
# bin/ccp 分派到 add 时 source 本文件并调用 _ccp_cmd_add；返回值即 ccp 的退出码。

_ccp_cmd_add() {
  emulate -L zsh
  if (( $# != 1 )); then
    print -u2 -r -- "用法：ccp add <名字>"
    return 2
  fi
  local name=$1 root dir

  # 先做完全部检查，再动磁盘：任何一项不通过都不创建、不修改任何文件
  if ! _ccp_valid_name "$name"; then
    print -u2 -r -- "ccp add: 档案名 \"$name\" 不合规（只能包含字母、数字、. _ -，且以字母或数字开头）。"
    return 1
  fi
  if _ccp_reserved_name "$name"; then
    print -u2 -r -- "ccp add: \"$name\" 是保留名，不能用作档案名。"
    return 1
  fi
  root=$(_ccp_profiles_root)
  dir=$(_ccp_profile_dir "$name")
  if [[ -e $dir || -L $dir ]]; then
    print -u2 -r -- "ccp add: 档案 \"$name\" 已存在（$dir）。用 \`ccp ls\` 查看已有档案。"
    return 1
  fi

  # 只创建档案目录本身（不带 -p），即使有人同时创建了同名档案也不会混用
  /bin/mkdir -p -- "$root" && /bin/mkdir -- "$dir" || {
    print -u2 -r -- "ccp add: 无法创建档案目录 $dir"
    return 1
  }
  if ! _ccp_share_resources "$dir"; then
    print -u2 -r -- "ccp add: 无法建立共享资源的软链接，已撤销创建。"
    /bin/rm -rf -- "$dir"
    return 1
  fi
  if ! _ccp_seed_settings_json "$dir"; then
    print -u2 -r -- "ccp add: 无法复制默认档案的 $(_ccp_default_config_dir)/settings.json，新档案从 Claude Code 的默认设置开始。"
  fi
  if ! _ccp_seed_claude_json "$dir"; then
    print -u2 -r -- "ccp add: 没有读到默认档案的 $(_ccp_default_claude_json)（不存在或无法解析），新档案不带 MCP 服务器和项目列表的初始值。"
  fi

  print -r -- "已创建档案 \"$name\"（$dir）。"
  print -r -- "正在进入这个档案的 Claude Code，请完成首次引导和登录，完成后退出即可。"
  # 在档案目录里的专用空目录中启动（见 lib/launch.zsh），不在调用者的当前目录
  _ccp_launch_profile_claude add "$dir"
}

# ---------- .claude.json 的初始值 ----------

# 输出默认档案的 .claude.json 路径：$HOME/.claude.json（去掉 HOME 结尾的 /）
_ccp_default_claude_json() {
  emulate -L zsh
  setopt extended_glob
  print -r -- "${HOME%%/##}/.claude.json"
}

# 从默认档案的 .claude.json（$HOME/.claude.json，不在 ~/.claude/ 里）中只取 mcpServers 和
# projects 两个字段，写成新档案的 .claude.json，作为一次性的初始值。其他字段（账号资料、
# 首次引导的完成状态等）一律不复制；默认档案没有的字段也不写。值原样保留（含 null、带点的键名、
# 非 ASCII 键名）。只读默认档案，不修改它。
# 默认档案的 .claude.json 不存在、无法解析或顶层不是对象时：不写初始值，返回 1。
# 参数：新档案目录
_ccp_seed_claude_json() {
  emulate -L zsh
  local src dst="$1/.claude.json" tmp="$1/.claude.json.ccp-tmp"
  src=$(_ccp_default_claude_json)
  if /usr/bin/osascript -l JavaScript - "$src" > "$tmp" 2>/dev/null <<'EOF'
ObjC.import('Foundation');
function run(argv) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (s.isNil()) throw new Error('cannot read');
  const src = JSON.parse(s.js);
  if (src === null || typeof src !== 'object' || Array.isArray(src)) throw new Error('not an object');
  const out = {};
  for (const k of ['mcpServers', 'projects']) {
    if (Object.prototype.hasOwnProperty.call(src, k)) out[k] = src[k];
  }
  return JSON.stringify(out, null, 2);
}
EOF
  then
    /bin/mv -f -- "$tmp" "$dst" && return 0
  fi
  /bin/rm -f -- "$tmp"
  return 1
}

# ---------- settings.json 的初始值 ----------

# 把默认档案的 settings.json 复制为新档案自己的 settings.json（普通文件），作为一次性的初始值；
# 之后各档案各改各的（ADR 0003）。默认档案的是软链接时复制它指向的内容。只读默认档案，不修改它。
# 默认档案没有 settings.json 时什么都不写（Claude Code 第一次写设置时会自己创建），返回 0；
# 有但复制失败时不留下文件，返回 1。参数：新档案目录
_ccp_seed_settings_json() {
  emulate -L zsh
  local src dst="$1/settings.json" tmp="$1/settings.json.ccp-tmp"
  src=$(_ccp_default_config_dir)/settings.json
  [[ -e $src ]] || return 0
  if /bin/cp -- "$src" "$tmp" 2>/dev/null; then
    /bin/mv -f -- "$tmp" "$dst" && return 0
  fi
  /bin/rm -f -- "$tmp"
  return 1
}

# ---------- 共享资源 ----------
# 共享资源的清单和建立方式只在这里定义。目前对每一项建软链接，指向默认档案中的同名项；
# 默认档案里还不存在的项也照样建（悬空链接），等默认档案里有了这一项，新档案立即可见。
# settings.json 不在其中：每个档案一份，见上面的 _ccp_seed_settings_json。

# 输出共享资源清单，每行一项（目录也不带结尾的 /）
_ccp_shared_resources() {
  emulate -L zsh
  print -rl -- CLAUDE.md skills agents commands plugins projects
}

# 在新档案目录里建立全部共享资源。参数：档案目录（应为刚创建的空目录）
_ccp_share_resources() {
  emulate -L zsh
  local dir=$1 src item
  src=$(_ccp_default_config_dir)
  for item in ${(f)"$(_ccp_shared_resources)"}; do
    /bin/ln -s -- "$src/$item" "$dir/$item" || return 1
  done
}
