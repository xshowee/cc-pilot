# cc-pilot 共享库：钥匙串 service 名计算（与 Claude Code 2.1.309 的实现一致）。
#
# 规则（spec "钥匙串 service 名"）：
#   默认档案（不设置 CLAUDE_CONFIG_DIR）：Claude Code-credentials
#   其他档案：Claude Code-credentials- 加上 sha256(NFC(配置目录字符串)) 十六进制的前 8 位。
#   对传给 CLAUDE_CONFIG_DIR 的原始字符串计算：不展开 ~，不去掉结尾的 /。
# 只用 macOS 自带的工具：NFC 规范化用 osascript -l JavaScript，sha256 用 shasum。
#
# 这也是跨端一致性检查的基准：App 核心（Swift）对同一组路径必须算出相同结果，
# 测试向量见 tests/fixtures/service-names.tsv。从外部调用的方式：
#   zsh -f -c 'source "$1" && _ccp_service_name "${@:2}"' _ <仓库>/shell/lib/keychain.zsh [配置目录]
#
# 函数命名约定同 profiles.zsh：_ccp_ 前缀，emulate -L zsh，只 return 不 exit。

# _ccp_service_name [配置目录]
# 不带参数：默认档案；带一个参数（哪怕为空字符串）：按该字符串计算。
# 输出 service 名；osascript 或 shasum 失败时返回非零。
_ccp_service_name() {
  emulate -L zsh
  setopt extended_glob
  if (( $# == 0 )); then
    print -r -- "Claude Code-credentials"
    return 0
  fi
  local nfc digest
  nfc=$(/usr/bin/osascript -l JavaScript - "$1" <<'EOF'
function run(argv) { return argv[0].normalize('NFC'); }
EOF
  ) || return 1
  # osascript 在结果后面加一个换行，$(...) 已经去掉了它
  digest=$(print -rn -- "$nfc" | /usr/bin/shasum -a 256) || return 1
  [[ $digest == [0-9a-f](#c64)\ * ]] || return 1
  print -r -- "Claude Code-credentials-${digest[1,8]}"
}
