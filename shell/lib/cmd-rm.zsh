# ccp rm <名字>（ticket 04）。bin/ccp 分派到 rm 时 source 本文件并调用 _ccp_cmd_rm。
# 参数：ccp rm 之后的全部参数；返回值即 ccp 的退出码。
#
# 流程（spec "ccp 命令 / rm"）：
#   1. 请用户确认（从标准输入读一行，y / yes 才继续；其他回答或读不到都算拒绝）。
#   2. 直接设置 CLAUDE_CONFIG_DIR 启动该档案的 Claude Code，等用户在里面 /logout 并退出。
#   3. 用 _ccp_service_name 算出该档案的钥匙串 service 名，
#      用 `security find-generic-password -s <service>` 检查钥匙串项是否还存在。
#      不带 -w：只判断是否存在，不读取凭据内容。
#   4. 退出码 0（还在）：拒绝删除，提示先 /logout。退出码 44（不存在）：删除档案目录。
#      其他退出码（查询失败）：无法确认已登出，同样拒绝删除。
# 输出位置与其他子命令相同：询问、进度和结果写 stdout，错误和用法写 stderr。

_ccp_cmd_rm() {
  emulate -L zsh
  local name dir svc answer active
  integer rc

  # 所有检查都放在确认、启动 Claude Code 和查询钥匙串之前
  if (( $# != 1 )); then
    print -u2 -r -- "用法：ccp rm <名字>"
    return 2
  fi
  name=$1
  if [[ $name == default ]]; then
    print -u2 -r -- "ccp rm: 默认档案不能删除。"
    return 1
  fi
  if ! _ccp_valid_name "$name"; then
    print -u2 -r -- "ccp rm: 档案名 \"$name\" 不合规（只能包含字母、数字、. _ -，且以字母或数字开头）。"
    return 1
  fi
  dir=$(_ccp_profile_dir "$name")
  active=$(_ccp_active_name)
  # 当前档案记录可能只与目录名差在大小写（手写或旧版本写入）：按是否同一个目录判断
  if [[ $name == "$active" ]] \
      || { [[ $active != default ]] && _ccp_valid_name "$active" && [[ $(_ccp_profile_dir "$active") -ef $dir ]] }; then
    print -u2 -r -- "ccp rm: \"$name\" 是当前档案，不能删除。请先用 \`ccp use <其他档案>\` 切换（例如 \`ccp use default\`）。"
    return 1
  fi
  if ! _ccp_profile_exists "$name"; then
    print -u2 -r -- "ccp rm: 档案 \"$name\" 不存在（$dir）。可以用 \`ccp ls\` 查看已有档案。"
    _ccp_print_case_hint "$name"
    return 1
  fi

  svc=$(_ccp_service_name "$dir") || {
    print -u2 -r -- "ccp rm: 无法计算档案 \"$name\" 的钥匙串 service 名。"
    return 1
  }

  print -rn -- "确定要删除档案 \"$name\"（$dir）吗？[y/N] "
  if ! IFS= read -r answer || [[ $answer != ([yY]|[yY][eE][sS]) ]]; then
    print -r -- "已取消，没有删除任何东西。"
    return 1
  fi

  print -r -- "接下来会打开档案 \"$name\" 的 Claude Code：请在里面执行 /logout，然后退出。"
  CLAUDE_CONFIG_DIR=$dir command claude

  security find-generic-password -s "$svc" >/dev/null 2>&1
  rc=$?
  if (( rc == 0 )); then
    print -u2 -r -- "ccp rm: 档案 \"$name\" 仍处于登录状态（钥匙串项 \"$svc\" 还在），没有删除。"
    print -u2 -r -- "  请重新执行 \`ccp rm $name\`，在打开的 Claude Code 里执行 /logout 后再退出。"
    return 1
  elif (( rc != 44 )); then
    print -u2 -r -- "ccp rm: 查询钥匙串失败（security 退出码 $rc），无法确认档案 \"$name\" 已登出，没有删除。"
    return 1
  fi

  /bin/rm -rf -- "$dir" || {
    print -u2 -r -- "ccp rm: 删除 $dir 失败。"
    return 1
  }
  print -r -- "已删除档案 \"$name\"。"
}
