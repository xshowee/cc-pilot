# cc-pilot shell 黑盒测试的辅助库。
#
# 用法：每个测试文件 tests/shell/test-<功能>.zsh 以 `#!/bin/zsh -f` 开头、可执行，
#   source "${0:A:h}/lib.zsh"
#   test_xxx() { ... }        # 每个 test_ 开头的函数是一个用例，按名字排序依次运行
#   t_main "$@"               # 放在文件末尾；可传一个模式只跑名字匹配的用例
#
# 每个用例在独立的子 shell 里运行，并拥有：
#   $T          这个用例的临时根目录（结束后删除）
#   $T_HOME     临时用户主目录（路径里故意带空格），所有被测程序都以它为 HOME
#               其中 $T_HOME/.cc-pilot/ 是仓库 shell/ 目录的原样复制（即安装后的布局）
#   $T_CLAUDE_LOG  假 claude 的记录目录
#   $T_SECURITY    假 security 的钥匙串内容和调用记录（即 FAKE_SECURITY_DIR，格式见 tests/fakes/security）
# 被测程序一律通过 t_run / t_claude / t_zsh / t_ccp / t_ccp_in 启动：`env -i` 清空环境，
# PATH 最前面是 tests/fakes/（假 claude、假 security），然后才是 /usr/bin:/bin:/usr/sbin:/sbin。
# 标准输入默认是 /dev/null；用 t_stdin 准备输入（例如回答确认提示）。
# 运行结果在 $T_OUT、$T_ERR、$T_RC 里。

emulate -R zsh
setopt extended_glob

ROOT=${${(%):-%x}:A:h:h:h}
SHELL_SRC=$ROOT/shell
FAKES=$ROOT/tests/fakes
FIXTURES=$ROOT/tests/fixtures

# ---------- 准备环境 ----------

# 创建档案目录：t_profile work personal
t_profile() {
  local n
  for n in "$@"; do mkdir -p -- "$T_HOME/.claude-profiles/$n" || exit 1; done
}

# 写当前档案记录（一行）：t_active work
t_active() {
  mkdir -p -- "$T_HOME/.claude-profiles" || exit 1
  print -r -- "$1" > "$T_HOME/.claude-profiles/active" || exit 1
}

# 准备之后每次运行被测程序时的标准输入（自动补一个换行）：t_stdin y
t_stdin() {
  print -r -- "$1" > $T/stdin || exit 1
  T_STDIN=$T/stdin
}

# 在假钥匙串里加一条钥匙串项：t_keychain_item 服务 [账户，默认 tester] [-w 输出的内容，默认为空]
t_keychain_item() {
  local dir=$T_SECURITY/items/$1
  mkdir -p -- $dir || exit 1
  print -rn -- "${3-}" > $dir/${2:-tester} || exit 1
}

# ---------- 启动被测程序 ----------

# t_run [VAR=值 ...] [--] 命令 参数...
# 在干净环境里运行命令。开头的 VAR=值 会追加进环境（可覆盖默认值）；
# 之后可选一个 `--`，用来隔开形如 VAR=值 的普通参数。t_claude / t_zsh / t_ccp 同理。
t_run() {
  local -a extra
  while [[ ${1-} == [A-Za-z_][A-Za-z0-9_]#=* ]]; do extra+=("$1"); shift; done
  [[ ${1-} == -- ]] && shift
  env -i \
    HOME=$T_HOME \
    PATH=$FAKES:/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=en_US.UTF-8 \
    FAKE_CLAUDE_LOG_DIR=$T_CLAUDE_LOG \
    FAKE_SECURITY_DIR=$T_SECURITY \
    "${extra[@]}" \
    "$@" > $T/out 2> $T/err < ${T_STDIN:-/dev/null}
  T_RC=$?
  T_OUT=$(< $T/out)
  T_ERR=$(< $T/err)
}

# t_claude [VAR=值 ...] [--] 参数...
# 在一个新的 zsh 里 source 已安装的 cc-pilot.zsh，然后调用 claude 包装函数。
t_claude() {
  local -a extra
  while [[ ${1-} == [A-Za-z_][A-Za-z0-9_]#=* ]]; do extra+=("$1"); shift; done
  [[ ${1-} == -- ]] && shift
  t_run "${extra[@]}" -- /bin/zsh -f -c \
    'source "$HOME/.cc-pilot/cc-pilot.zsh" || exit 98; claude "$@"' _ "$@"
}

# t_zsh [VAR=值 ...] [--] 代码 参数...
# 在一个新的 zsh 里 source 已安装的 cc-pilot.zsh 之后执行一段代码（参数为 $1 $2 ...）。
t_zsh() {
  local -a extra
  while [[ ${1-} == [A-Za-z_][A-Za-z0-9_]#=* ]]; do extra+=("$1"); shift; done
  [[ ${1-} == -- ]] && shift
  local code=$1; shift
  t_run "${extra[@]}" -- /bin/zsh -f -c \
    "source \"\$HOME/.cc-pilot/cc-pilot.zsh\" || exit 98; $code" _ "$@"
}

# t_ccp [VAR=值 ...] [--] 参数...
# 直接执行已安装的 ccp。
t_ccp() {
  local -a extra
  while [[ ${1-} == [A-Za-z_][A-Za-z0-9_]#=* ]]; do extra+=("$1"); shift; done
  [[ ${1-} == -- ]] && shift
  t_run "${extra[@]}" -- "$T_HOME/.cc-pilot/bin/ccp" "$@"
}

# t_ccp_in 目录 [VAR=值 ...] [--] 参数...
# 先在一个新的 zsh 里 cd 到这个目录（模拟用户在这里输入命令；App 打开的终端里是 ~），
# 再执行已安装的 ccp。ccp 结束后，这个 shell（调用者）的当前目录写进 $T/caller-pwd。
t_ccp_in() {
  local dir=$1; shift
  local -a extra
  while [[ ${1-} == [A-Za-z_][A-Za-z0-9_]#=* ]]; do extra+=("$1"); shift; done
  [[ ${1-} == -- ]] && shift
  t_run CALLER_PWD_FILE=$T/caller-pwd "${extra[@]}" -- /bin/zsh -f -c \
    'cd -- "$1" || exit 97; shift; "$HOME/.cc-pilot/bin/ccp" "$@"; rc=$?
     print -r -- "$PWD" > "$CALLER_PWD_FILE"; exit $rc' _ "$dir" "$@"
}

# ---------- 读取假 claude 的记录 ----------

# 假 claude 被调用的次数
claude_calls() {
  local -a files
  files=($T_CLAUDE_LOG/<->(N.))
  print -r -- ${#files}
}

# claude_field 键 [第几次调用，默认最后一次]：输出该键的值
claude_field() {
  local n=${2:-$(claude_calls)} line
  [[ -f $T_CLAUDE_LOG/$n ]] || fail "假 claude 没有第 $n 次调用的记录"
  while IFS= read -r line; do
    if [[ $line == $1=* ]]; then print -r -- "${line#$1=}"; return 0; fi
  done < $T_CLAUDE_LOG/$n
  return 1
}

# claude_args [第几次调用]：把参数放进数组 reply
claude_args() {
  local n=${1:-$(claude_calls)} line
  reply=()
  [[ -f $T_CLAUDE_LOG/$n ]] || fail "假 claude 没有第 $n 次调用的记录"
  while IFS= read -r line; do
    [[ $line == arg=* ]] && reply+=("${line#arg=}")
  done < $T_CLAUDE_LOG/$n
}

# ---------- 读取假 security 的记录 ----------

# 假 security 被调用的次数
security_calls() {
  local -a files
  files=($T_SECURITY/calls/<->(N.))
  print -r -- ${#files}
}

# security_args [第几次调用，默认最后一次]：把参数放进数组 reply
security_args() {
  local n=${1:-$(security_calls)} line
  reply=()
  [[ -f $T_SECURITY/calls/$n ]] || fail "假 security 没有第 $n 次调用的记录"
  while IFS= read -r line; do
    [[ $line == arg=* ]] && reply+=("${line#arg=}")
  done < $T_SECURITY/calls/$n
}

# ---------- 断言（失败即结束当前用例） ----------

fail() {
  print -u2 -r -- "    FAIL: $*"
  [[ -n ${T_RC-} ]] && print -u2 -r -- "    最后一次运行：rc=$T_RC"
  [[ -n ${T_OUT-} ]] && print -u2 -r -- "    stdout: $T_OUT"
  [[ -n ${T_ERR-} ]] && print -u2 -r -- "    stderr: $T_ERR"
  exit 1
}

assert_eq() {  # 实际值 期望值 说明
  [[ $1 == "$2" ]] || fail "$3: 得到 [$1]，期望 [$2]"
}

assert_ne() {  # 值1 值2 说明
  [[ $1 != "$2" ]] || fail "$3: 两者不应相同，都是 [$1]"
}

assert_contains() {  # 文本 子串 说明
  [[ $1 == *"$2"* ]] || fail "$3: [$1] 中没有 [$2]"
}

assert_rc() {  # 期望的退出码
  [[ $T_RC == $1 ]] || fail "退出码为 $T_RC，期望 $1"
}

assert_rc_nonzero() {
  (( T_RC != 0 )) || fail "退出码为 0，期望非零"
}

assert_stderr_empty() {
  [[ -z $T_ERR ]] || fail "stderr 应为空"
}

assert_claude_calls() {  # 期望的调用次数
  assert_eq "$(claude_calls)" "$1" "假 claude 的调用次数"
}

assert_claude_config_dir_unset() {  # [第几次调用]
  assert_eq "$(claude_field config_dir_set $1)" no "CLAUDE_CONFIG_DIR 应当未设置"
}

assert_claude_config_dir() {  # 期望值 [第几次调用]
  assert_eq "$(claude_field config_dir_set $2)" yes "CLAUDE_CONFIG_DIR 应当已设置"
  assert_eq "$(claude_field config_dir $2)" "$1" "CLAUDE_CONFIG_DIR"
}

assert_claude_args() {  # 期望的参数...（最后一次调用）
  local -a reply
  claude_args
  assert_eq "$(claude_field argc)" "$#" "假 claude 收到的参数个数"
  local i
  for (( i = 1; i <= $#; i++ )); do
    assert_eq "${reply[i]}" "${@[i]}" "第 $i 个参数"
  done
}

# 经包装函数启动、实时额度开启（默认）时，包装函数在用户参数前面加了状态栏覆盖
# （--settings 和一段 JSON，见 test-statusline.zsh）。断言最后一次调用带着它，之后是期望的用户参数。
assert_wrapper_args() {  # 期望的用户参数...
  local -a reply
  claude_args
  assert_eq "${reply[1]-}" --settings "第 1 个参数应是状态栏覆盖的 --settings"
  assert_contains "${reply[2]-}" '{"statusLine":' "第 2 个参数应是状态栏覆盖"
  assert_eq "$(claude_field argc)" "$(( $# + 2 ))" "假 claude 收到的参数个数（含状态栏覆盖）"
  local i
  for (( i = 1; i <= $#; i++ )); do
    assert_eq "${reply[i+2]}" "${@[i]}" "第 $i 个用户参数"
  done
}

# ---------- ccp add / rm 启动 Claude Code 的工作目录（ticket 21） ----------

# 断言最后一次 claude 是在档案 $1 目录里的某个子目录中启动的，且不是调用者所在的目录 $2；
# 调用者 shell 的当前目录仍是 $2。输出 claude 的工作目录。
assert_claude_in_neutral_dir() {  # 档案名 调用者所在目录
  local cwd profile=${T_HOME}/.claude-profiles/$1
  cwd=$(claude_field cwd) || fail "假 claude 没有记录工作目录"
  [[ $cwd == ${profile:A}/?* ]] || fail "claude 应在档案目录 $profile 里的子目录中启动，实际是 [$cwd]"
  assert_ne "$cwd" "${2:A}" "claude 的工作目录不应是调用者所在的目录"
  assert_ne "$cwd" "${T_HOME:A}" "claude 的工作目录不应是 ~"
  assert_eq "$(< $T/caller-pwd)" "$2" "调用者 shell 的当前目录"
  print -r -- "$cwd"
}

# 临时 HOME 和测试临时目录 $T/tmp 下，除档案 $1 的目录和安装目录以外每一项的路径和类型
# （不比较目录的大小和修改时间：新建档案目录本身会改变档案根目录的这两项）
outside_profile_snapshot() {  # 档案名
  /usr/bin/find "$T_HOME" "$T/tmp" \( -path "$T_HOME/.cc-pilot" -o -path "$T_HOME/.claude-profiles/$1" \) -prune \
    -o -print0 | /usr/bin/xargs -0 /usr/bin/stat -f '%N|%HT' | /usr/bin/sort
}

# ---------- 运行 ----------

t_main() {
  local pattern=${1:-*} name rc
  integer passed=0 failures=0
  local -a tests
  tests=(${(ok)functions[(I)test_*]})
  if (( ${#tests} == 0 )); then
    print -u2 -r -- "${ZSH_ARGZERO:t}: 没有任何 test_ 用例"
    exit 1
  fi
  for name in $tests; do
    [[ $name == $~pattern ]] || continue
    T=$(mktemp -d "${${TMPDIR:-/tmp}%/}/ccp-test.XXXXXX") || exit 1
    T_HOME="$T/home dir"
    T_CLAUDE_LOG=$T/claude-log
    T_SECURITY=$T/security
    mkdir -p -- $T_HOME && cp -R -- $SHELL_SRC $T_HOME/.cc-pilot || exit 1
    ( unset T_RC T_OUT T_ERR T_STDIN; $name )
    rc=$?
    rm -rf -- $T
    if (( rc == 0 )); then
      (( passed++ ))
      print -r -- "  ok   $name"
    else
      (( failures++ ))
      print -r -- "  FAIL $name"
    fi
  done
  print -r -- "  ${ZSH_ARGZERO:t}: $passed 通过，$failures 失败"
  (( failures == 0 ))
  exit $?
}
