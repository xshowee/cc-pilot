#!/bin/zsh -f
# ccp init / uninstall：把包装函数接入 zsh，以及彻底移除接入（ticket 02）
source "${0:A:h}/lib.zsh"

# init 写入 ~/.zshrc 的那一行（与 shell/README.md 中的说明一致）
LINE='source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot'

ZSHRC() { print -r -- "$T_HOME/.zshrc" }

# 带标准输入运行 ccp：ccp_input 输入 参数...
ccp_input() {
  local input=$1; shift
  t_run -- /bin/zsh -f -c 'print -rn -- "$1" | "$2" "${@:3}"' _ "$input" \
    "$T_HOME/.cc-pilot/bin/ccp" "$@"
}

# 把一个文件的原始字节保存一份，供之后按字节比较：snapshot 文件 副本
snapshot() { /bin/cp -p -- "$1" "$2" || fail "无法复制 $1" }

assert_same_bytes() {  # 文件1 文件2 说明
  /usr/bin/cmp -s -- "$1" "$2" || fail "$3: 字节不一致
$(/usr/bin/od -c -- "$1" | /usr/bin/tail -5)
-- 期望 --
$(/usr/bin/od -c -- "$2" | /usr/bin/tail -5)"
}

# 输出某个文件中与 LINE 完全相同的行数
line_count() {
  local n=0 l
  [[ -e $1 ]] || { print 0; return }
  while IFS= read -r l || [[ -n $l ]]; do [[ $l == "$LINE" ]] && (( n++ )); done < $1
  print -r -- $n
}

# 一份"复杂"的 zshrc：空行、结尾多个空行、CRLF 行、注释里包含接入行的文字、非 UTF-8 字节
write_tricky_zshrc() {
  printf '%s\n' '# my zshrc' '' 'export FOO=1' > $1
  printf 'alias x=y\r\n' >> $1
  printf '%s\n' "# $LINE" "#$LINE" " $LINE" "${LINE}x" >> $1
  printf 'echo \377\376 bytes\n' >> $1
  printf '\n\n' >> $1
}

# ---------- ccp init ----------

test_init_declined_changes_nothing() {
  write_tricky_zshrc "$(ZSHRC)"
  snapshot "$(ZSHRC)" $T/orig
  ccp_input $'n\n' init
  assert_rc_nonzero
  assert_contains "$T_OUT" "$LINE" "征求同意时应列出要写入的那一行"
  assert_same_bytes "$(ZSHRC)" $T/orig "~/.zshrc 应保持不变"
}

test_init_without_answer_changes_nothing() {
  # 标准输入为空（例如非交互调用又没带 --yes）视同拒绝
  t_ccp init
  assert_rc_nonzero
  [[ ! -e $(ZSHRC) && ! -L $(ZSHRC) ]] || fail "不应创建 ~/.zshrc"
}

test_init_confirmed_appends_one_line() {
  write_tricky_zshrc "$(ZSHRC)"
  snapshot "$(ZSHRC)" $T/orig
  ccp_input $'y\n' init
  assert_rc 0
  { /bin/cat -- $T/orig; print -r -- "$LINE" } > $T/expected
  assert_same_bytes "$(ZSHRC)" $T/expected "应在末尾追加一行"
}

test_init_accepts_yes_in_any_case() {
  ccp_input $'YES\n' init
  assert_rc 0
  assert_eq "$(line_count "$(ZSHRC)")" 1 "接入行的数量"
}

test_init_yes_flag_skips_confirmation() {
  local flag
  for flag in --yes -y; do
    rm -f -- "$(ZSHRC)"
    t_ccp init $flag
    assert_rc 0
    assert_eq "$(line_count "$(ZSHRC)")" 1 "接入行的数量"
  done
}

test_init_creates_missing_zshrc_with_only_the_line() {
  t_ccp init --yes
  assert_rc 0
  print -r -- "$LINE" > $T/expected
  assert_same_bytes "$(ZSHRC)" $T/expected "新建的 ~/.zshrc"
}

test_init_terminates_last_line_when_zshrc_lacks_final_newline() {
  printf 'export FOO=1' > "$(ZSHRC)"
  t_ccp init --yes
  assert_rc 0
  printf '%s\n' 'export FOO=1' "$LINE" > $T/expected
  assert_same_bytes "$(ZSHRC)" $T/expected "接入行应单独成行"
}

test_init_repeated_writes_only_one_line_and_does_not_ask_again() {
  ccp_input $'y\n' init
  assert_rc 0
  t_ccp init --yes
  assert_rc 0
  t_ccp init            # 已接入：不再询问，标准输入为空也成功
  assert_rc 0
  ccp_input $'y\n' init
  assert_rc 0
  assert_eq "$(line_count "$(ZSHRC)")" 1 "接入行的数量"
}

test_init_ignores_lookalike_lines_and_still_appends() {
  write_tricky_zshrc "$(ZSHRC)"
  t_ccp init --yes
  assert_rc 0
  assert_eq "$(line_count "$(ZSHRC)")" 1 "接入行的数量"
}

test_init_writes_through_symlinked_zshrc() {
  mkdir -p -- "$T/dotfiles"
  print -r -- 'export FOO=1' > "$T/dotfiles/zshrc"
  ln -s -- "$T/dotfiles/zshrc" "$(ZSHRC)"
  t_ccp init --yes
  assert_rc 0
  [[ -L $(ZSHRC) ]] || fail "~/.zshrc 应仍是软链接"
  assert_eq "$(/usr/bin/readlink -- "$(ZSHRC)")" "$T/dotfiles/zshrc" "软链接的指向"
  printf '%s\n' 'export FOO=1' "$LINE" > $T/expected
  assert_same_bytes "$T/dotfiles/zshrc" $T/expected "软链接指向的文件"
}

test_new_shell_after_init_uses_wrapper_and_ccp() {
  t_profile work
  t_active work
  t_ccp init --yes
  assert_rc 0
  t_run -- /bin/zsh -f -c 'source "$HOME/.zshrc"; whence -w claude; whence -p ccp; claude hi'
  assert_rc 0
  assert_eq "$T_OUT" "claude: function
$T_HOME/.cc-pilot/bin/ccp" "新 shell 里的 claude 和 ccp"
  assert_claude_config_dir "$T_HOME/.claude-profiles/work"
  assert_claude_args hi
}

test_init_refuses_when_cc_pilot_is_not_installed() {
  rm -f -- "$T_HOME/.cc-pilot/cc-pilot.zsh"
  t_ccp init --yes
  assert_rc_nonzero
  assert_contains "$T_ERR" ".cc-pilot/cc-pilot.zsh" "错误信息"
  [[ ! -e $(ZSHRC) ]] || fail "不应创建 ~/.zshrc"
}

test_init_unknown_argument_prints_usage() {
  t_ccp init --bogus
  assert_rc 2
  assert_contains "$T_ERR" "用法" "应输出用法说明"
  [[ ! -e $(ZSHRC) ]] || fail "不应创建 ~/.zshrc"
}

t_main "$@"
