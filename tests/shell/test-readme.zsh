#!/bin/zsh -f
# ticket 15：README（英文 README.md、中文 README.zh-CN.md）与代码保持一致。
#
# README 是写给人看的，大部分内容只能人工核对；这里只检查那些能从代码里机械地取到真值的事实：
#   - 命令表：两份 README 的命令表各自列出的 ccp 子命令，与 shell/lib/cmd-*.zsh 完全一致。
#     命令表的每一行以 "| `ccp <命令>" 开头（README 里约定的写法），其他地方提到 ccp 不算。
#   - 接入行：README 里写的 ~/.zshrc 接入行与 ccp init 实际写入的逐字节相同。
#   - 联网承诺：README 写出的六个地址就是代码里的三个额度接口（Claude Code、ChatGPT、Kimi Code）、Kimi Code 的模型列表接口、
#     账户信息接口和 Info.plist 的 SUFeedURL。
source "${0:A:h}/lib.zsh"

READMES=($ROOT/README.md $ROOT/README.zh-CN.md)

# 输出某份 README 命令表里的 ccp 子命令，每行一个，排序去重
readme_commands() {
  local line
  local -a cmds
  while IFS= read -r line; do
    [[ $line == (#b)'| `ccp '([a-z]##)* ]] && cmds+=($match[1])
  done < $1
  print -rl -- ${(ou)cmds}
}

test_both_readmes_exist_and_link_to_each_other() {
  [[ -f $ROOT/README.md ]] || fail "缺少 README.md"
  [[ -f $ROOT/README.zh-CN.md ]] || fail "缺少 README.zh-CN.md"
  assert_contains "$(< $ROOT/README.md)" "(README.zh-CN.md)" "英文 README 链接到中文版"
  assert_contains "$(< $ROOT/README.zh-CN.md)" "(README.md)" "中文 README 链接到英文版"
}

test_command_tables_match_the_ccp_subcommands() {
  local -a files
  # statusline 是 claude 包装函数挂到状态栏上的内部命令（token-usage ticket 04），不给用户用，不进命令表；
  # cmd-chatgpt-<子命令>.zsh 是 ccp chatgpt 的第二级子命令，命令表里归在 chatgpt 名下
  files=($ROOT/shell/lib/cmd-^(statusline|chatgpt-*).zsh)
  local expected=${(F)${(o)${files:t:r}#cmd-}}
  # 给用户用的共八个子命令：原有七个加上 chatgpt（chatgpt-profiles ticket 02）
  assert_eq "${#files}" 8 "shell/lib/cmd-*.zsh 的个数"
  local readme
  for readme in $READMES; do
    assert_eq "$(readme_commands $readme)" "$expected" "${readme:t} 命令表里的 ccp 子命令"
  done
}

test_readmes_show_the_exact_zshrc_line() {
  local line
  line=$(source $ROOT/shell/lib/zshrc.zsh && _ccp_zshrc_line)
  [[ -n $line ]] || fail "取不到接入行"
  local readme
  for readme in $READMES; do
    assert_contains "$(< $readme)" "$line" "${readme:t} 里的接入行"
  done
}

test_readmes_name_the_only_six_network_addresses() {
  local endpoint chatgpt_endpoint kimi_endpoint kimi_models kimi_me feed
  endpoint=$(sed -n 's/.*static let endpoint = URL(string: "\([^"]*\)").*/\1/p' \
    $ROOT/Sources/Core/UsageRefresher.swift)
  [[ $endpoint == https://* ]] || fail "取不到额度接口地址：[$endpoint]"
  # ChatGPT 的额度接口（chatgpt-profiles ticket 07、12）
  chatgpt_endpoint=$(sed -n 's/.*static let usageEndpoint = URL(string: "\([^"]*\)").*/\1/p' \
    $ROOT/Sources/Core/ChatGPTUsageRefresher.swift)
  [[ $chatgpt_endpoint == https://* ]] || fail "取不到 ChatGPT 额度接口地址：[$chatgpt_endpoint]"
  # Kimi Code 的额度接口（ADR 0007）
  kimi_endpoint=$(sed -n 's/.*static let usageEndpoint = URL(string: "\([^"]*\)").*/\1/p' \
    $ROOT/Sources/Core/KimiUsageRefresher.swift)
  [[ $kimi_endpoint == https://* ]] || fail "取不到 Kimi Code 额度接口地址：[$kimi_endpoint]"
  # Kimi Code 的模型列表接口（ADR 0007，2026-11-11 补充）
  kimi_models=$(sed -n 's/.*static let modelsEndpoint = URL(string: "\([^"]*\)").*/\1/p' \
    $ROOT/Sources/Core/KimiModels.swift)
  [[ $kimi_models == https://* ]] || fail "取不到 Kimi Code 模型列表接口地址：[$kimi_models]"
  kimi_me=$(sed -n 's/.*static let meEndpoint = URL(string: "\([^"]*\)").*/\1/p' \
    $ROOT/Sources/Core/KimiAccountInfo.swift)
  [[ $kimi_me == https://* ]] || fail "取不到 Kimi Code 账户信息接口地址：[$kimi_me]"
  feed=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" $ROOT/Resources/Info.plist)
  [[ $feed == https://* ]] || fail "取不到 SUFeedURL：[$feed]"
  local readme
  for readme in $READMES; do
    assert_contains "$(< $readme)" "$endpoint" "${readme:t} 写明额度接口"
    assert_contains "$(< $readme)" "$chatgpt_endpoint" "${readme:t} 写明 ChatGPT 额度接口"
    assert_contains "$(< $readme)" "$kimi_endpoint" "${readme:t} 写明 Kimi Code 额度接口"
    assert_contains "$(< $readme)" "$kimi_models" "${readme:t} 写明 Kimi Code 模型列表接口"
    assert_contains "$(< $readme)" "$kimi_me" "${readme:t} 写明 Kimi Code 账户信息接口"
    assert_contains "$(< $readme)" "$feed" "${readme:t} 写明更新检查地址"
  done
}

test_license_is_mit_by_xshowee_2026() {
  [[ -f $ROOT/LICENSE ]] || fail "缺少 LICENSE"
  local text=$(< $ROOT/LICENSE)
  [[ ${${(f)text}[1]} == "MIT License" ]] || fail "LICENSE 第一行应为 MIT License"
  assert_contains "$text" "Copyright (c) 2026 xshowee" "版权行"
  assert_contains "$text" "Permission is hereby granted, free of charge" "MIT 许可正文"
  assert_contains "$text" 'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND' "免责声明"
  local readme
  for readme in $READMES; do
    assert_contains "$(< $readme)" "(LICENSE)" "${readme:t} 链接到 LICENSE"
  done
}

t_main "$@"
