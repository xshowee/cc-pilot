#!/bin/zsh -f
# cc-pilot 统一检查入口：./scripts/check.sh
#
# 依次运行下面各项，全部跑完后汇总；任何一项失败都以非零状态退出。
#
# 1. 语法检查：对 shell/ 和 tests/ 下所有 zsh 文件执行 `zsh -n`。
# 2. shell 黑盒测试：自动发现 tests/shell/test-*.zsh（每个 ticket / 功能一个文件），
#    逐个直接执行（每个文件以 `#!/bin/zsh -f` 开头且可执行）。新增测试只需新增文件，
#    不必修改本脚本。测试辅助库是 tests/shell/lib.zsh，假程序放在 tests/fakes/。
# 3. Swift 检查程序（ticket 06 起）：当 Sources/Core/*.swift 和 tests/swift/*.swift
#    都存在时，用 swiftc 把它们编进同一个模块，生成 .build/checks/core-check 并运行，
#    第一个参数是仓库根目录（便于找到 shell/lib 和 tests/fixtures/ 里的测试向量）。
#    Sources/Core 只放不含界面的核心代码；@main 放在 tests/swift/ 里。
#    新增检查只需在 tests/swift/ 新增 CheckSuite 子类（见 tests/swift/CheckRunner.swift）。
# 4. App 类型检查（ticket 06 起）：Sources/App 存在时，按 Info.plist 的最低系统版本对
#    Sources/Core + Sources/App 做 swiftc -typecheck，并用 plutil 检查 Resources/ 下的资源文件。

emulate -R zsh
setopt extended_glob null_glob

ROOT=${0:A:h:h}
cd -- "$ROOT" || exit 1

typeset -a failed
step() { print -r -- "==> $*" }

# 1. 语法检查
step "zsh 语法检查"
typeset -a zsh_files
zsh_files=(shell/*.zsh shell/bin/*(.) shell/lib/*.zsh tests/shell/*.zsh tests/fakes/*(.x))
for f in $zsh_files; do
  if ! /bin/zsh -n -- $f; then
    failed+=("syntax: $f")
  fi
done

# 2. shell 黑盒测试
typeset -a shell_tests
shell_tests=(tests/shell/test-*.zsh)
if (( ${#shell_tests} == 0 )); then
  failed+=("没有发现任何 tests/shell/test-*.zsh")
fi
for t in $shell_tests; do
  step "shell 测试 $t"
  if [[ ! -x $t ]]; then
    failed+=("$t 不可执行（需要 chmod +x）")
    continue
  fi
  ./$t || failed+=("$t")
done

# 3. Swift 检查程序（存在时才编译运行）
typeset -a core_sources check_sources
core_sources=(Sources/Core/*.swift)
check_sources=(tests/swift/*.swift)
if (( ${#core_sources} && ${#check_sources} )); then
  step "Swift 检查程序"
  CHECK_BUILD=$ROOT/.build/checks
  mkdir -p -- $CHECK_BUILD
  if swiftc -parse-as-library -swift-version 5 \
      -sdk "$(xcrun --show-sdk-path)" \
      -module-cache-path $CHECK_BUILD/ModuleCache \
      $core_sources $check_sources -o $CHECK_BUILD/core-check; then
    $CHECK_BUILD/core-check $ROOT || failed+=("Swift 检查程序")
  else
    failed+=("Swift 检查程序编译失败")
  fi
fi

# 4. App 界面类型检查与资源文件检查（存在 Sources/App 时）：界面不做自动化测试，
#    但要保证它能按最低系统版本编译，资源文件格式正确。完整构建用 scripts/build-app.sh。
typeset -a app_sources resource_files
app_sources=(Sources/App/*.swift)
resource_files=(Resources/Info.plist Resources/*.lproj/*.strings)
if (( ${#app_sources} )); then
  step "App 类型检查（macOS $(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)+）"
  CHECK_BUILD=$ROOT/.build/checks
  mkdir -p -- $CHECK_BUILD
  swiftc -typecheck -parse-as-library -swift-version 5 \
      -sdk "$(xcrun --show-sdk-path)" \
      -target "$(uname -m)-apple-macos$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)" \
      -module-cache-path $CHECK_BUILD/ModuleCache \
      $core_sources $app_sources || failed+=("App 类型检查")
  step "资源文件检查"
  /usr/bin/plutil -lint -s $resource_files || failed+=("资源文件格式")
fi

print
if (( ${#failed} )); then
  print -u2 -r -- "检查失败（${#failed} 项）："
  for f in $failed; print -u2 -r -- "  - $f"
  exit 1
fi
print -r -- "全部检查通过"
