# cc-pilot 共享库（只给 ccp 用）：以某个档案启动 Claude Code（ccp add / ccp rm）。
#
# ccp 是独立的脚本进程，没有加载 claude 包装函数，CLAUDE_PROFILE 在这里不起作用：
# 直接把档案目录设为 CLAUDE_CONFIG_DIR（覆盖环境里已有的值），再 `command claude`。
#
# 工作目录（ticket 21）：claude 不在调用者的当前目录里启动，而是在档案目录里一个固定的空目录
# <档案目录>/.ccp-workdir 中启动。原因：
#   - Claude Code 第一次在某个目录里启动时会询问是否信任它（"Accessing workspace"，默认选项是
#     退出），结果按绝对路径记在各档案自己的 .claude.json 的 projects 里。新档案没有信任过调用者的
#     目录（App 打开的终端里是 ~）；在 ~ 下这个询问每次都会出现，还会把 ~/.claude/settings.json
#     当成项目设置，提示预先批准其中的工具权限。用户误选退出就中断了 add / rm。
#   - 路径固定：用户在 ccp add 里对它选过一次"信任"，同一档案之后的 ccp rm 就不会再问。
#   - 目录是空的：没有项目设置、CLAUDE.md 或可供读取的文件，选"信任"没有风险。
#   - 放在档案目录里：不在 ~ 或档案目录之外留下文件，ccp rm 删除档案时一并删除。
#     （系统临时目录则会让信任落在一个与 ccp 无关、其他程序也在写入的目录上。）
# cd 在子 shell 里进行，调用者的当前目录不变。

# 输出某个档案的 Claude Code 工作目录。参数：档案目录
_ccp_profile_workdir() {
  emulate -L zsh
  print -r -- "$1/.ccp-workdir"
}

# 在档案自己的工作目录里启动这个档案的 Claude Code，返回 claude 的退出码。
# 工作目录不存在时先建立（只建这一层，档案目录必须已存在）；建立失败时往 stderr 报错并返回 1，
# 不启动 claude。参数：子命令名（用于错误信息的前缀） 档案目录
_ccp_launch_profile_claude() {
  emulate -L zsh
  local cmd=$1 dir=$2 work
  work=$(_ccp_profile_workdir "$dir")
  if [[ ! -d $work ]] && ! /bin/mkdir -- "$work"; then
    print -u2 -r -- "ccp $cmd: 无法建立 Claude Code 的工作目录 $work"
    return 1
  fi
  print -r -- "Claude Code 若询问是否信任目录 $work：这是 ccp 专用的空目录，选 Yes 即可。"
  ( cd -- "$work" && CLAUDE_CONFIG_DIR=$dir command claude )
}
