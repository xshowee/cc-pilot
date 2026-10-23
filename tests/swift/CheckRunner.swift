// App 核心检查程序的入口（由 scripts/check.sh 编译运行：`core-check <仓库根目录> [名字片段]`）。
//
// 新增检查只需新增文件，不必修改本文件：在 tests/swift/ 下写一个 CheckSuite 的子类，
// 覆盖 `class var checks`，运行时会通过 Objective-C 运行时自动发现它。
//
//     final class FooChecks: CheckSuite {
//         override class var checks: [Check] {
//             [Check("某个行为") { try expect(1 + 1 == 2, "算错了") }]
//         }
//     }
//
// 所有套件按类名排序、每个检查按声明顺序运行；单个检查失败不影响其他检查，
// 最后汇总，有任何失败则以非零状态退出。第二个参数（可选）只运行名字包含该片段的检查。

import Foundation
import ObjectiveC

struct Check {
    let name: String
    let body: () throws -> Void
    init(_ name: String, _ body: @escaping () throws -> Void) {
        self.name = name
        self.body = body
    }
}

/// 检查套件的基类。子类覆盖 `checks` 即可被自动发现。
class CheckSuite: NSObject {
    class var checks: [Check] { [] }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String,
            file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition { throw CheckFailure(description: "\(file):\(line): \(message())") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                               file: StaticString = #fileID, line: UInt = #line) throws {
    if actual != expected {
        let what = message()
        throw CheckFailure(description:
            "\(file):\(line): \(what.isEmpty ? "" : what + ": ")得到 \(actual)，期望 \(expected)")
    }
}

/// 仓库根目录（第一个命令行参数）。
var repoRoot: URL {
    let args = CommandLine.arguments
    return URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
}

private func discoverSuites() -> [CheckSuite.Type] {
    // 只遍历本程序映像里的类（不碰系统框架的类，向它们发消息可能出问题）
    guard let image = class_getImageName(CheckSuite.self) else { return [] }
    var count: UInt32 = 0
    guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
    defer { free(UnsafeMutableRawPointer(mutating: names)) }
    let base = ObjectIdentifier(CheckSuite.self)
    var suites: [CheckSuite.Type] = []
    for i in 0..<Int(count) {
        guard let cls = objc_getClass(names[i]) as? AnyClass,
              let parent = class_getSuperclass(cls), ObjectIdentifier(parent) == base,
              let suite = cls as? CheckSuite.Type else { continue }
        suites.append(suite)
    }
    return suites.sorted { NSStringFromClass($0) < NSStringFromClass($1) }
}

@main
struct CoreCheck {
    static func main() {
        let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
        var passed = 0
        var failures: [String] = []
        for suite in discoverSuites() {
            let suiteName = NSStringFromClass(suite).components(separatedBy: ".").last ?? ""
            for check in suite.checks {
                let fullName = "\(suiteName): \(check.name)"
                if let filter, !fullName.contains(filter) { continue }
                do {
                    try check.body()
                    passed += 1
                    print("ok   \(fullName)")
                } catch {
                    failures.append(fullName)
                    print("FAIL \(fullName)\n     \(error)")
                }
            }
        }
        print("Swift 检查：\(passed) 项通过，\(failures.count) 项失败")
        if passed + failures.count == 0 {
            print("没有运行任何检查")
            exit(1)
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
