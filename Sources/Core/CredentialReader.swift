// 从钥匙串读取一个档案的凭据（spec "凭据读取"）。只读：只调用 `security find-generic-password`，
// 从不写入、删除或续期任何钥匙串项。
//
// 读取方法（调研笔记里 security 的实测行为）：
//   1. security find-generic-password -s <service> -a <当前用户名> -w
//      退出码 0 且内容不为空 → 用它
//      退出码 0 但为空、或 44（没有这个 account 的那条）→ 第 2 步
//      其他退出码、超时 → 读取失败，不再重试（可能是授权被拒，重试会再次弹窗）
//   2. security find-generic-password -s <service> -w（取第一条匹配）
//      0 → 用它（为空则是"钥匙串项为空"）；44 → 钥匙串项不存在；其他 → 读取失败
// 内容：去掉结尾换行后先按 JSON 解析；失败就当作十六进制（大小写均可）解码后再解析；
// 都失败是"格式无法识别"。security 的 -w 在内容含非 ASCII 字节时输出十六进制。
//
// 凭据只经过子进程的 stdout，命令行参数里只有 service 名和用户名；stderr 直接丢弃。
// 读到的凭据只作为返回值交给调用方，不缓存、不写盘、不记日志；错误信息里不带任何读到的内容。

import Foundation

/// 读不到可用凭据的原因（都不含凭据内容）
enum CredentialReadFailure: Error, Equatable {
    /// 钥匙串里没有这个 service 的项（security 退出码 44）
    case itemNotFound
    /// 钥匙串项存在，但内容为空
    case emptyItem
    /// 内容既不是 JSON，也不是十六进制编码的 JSON，或者没有 claudeAiOauth
    case unrecognizedFormat
    /// security 以其他退出码失败（例如授权被拒）；nil 表示 security 无法启动
    case readFailed(exitCode: Int32?)
    /// security 在限定时间内没有结束（通常是弹出了钥匙串授权窗口）
    case timedOut
}

struct CredentialReader {
    let environment: CoreEnvironment

    func read(service: String) -> Result<OAuthCredentials, CredentialReadFailure> {
        let output: Data
        switch run(["find-generic-password", "-s", service, "-a", environment.userName, "-w"]) {
        case .success(let r) where r.status == 0 && !Self.trimmed(r.stdout).isEmpty:
            output = r.stdout
        case .success(let r) where r.status == 0 || r.status == Self.notFoundStatus:
            switch run(["find-generic-password", "-s", service, "-w"]) {
            case .success(let r) where r.status == 0: output = r.stdout
            case .success(let r) where r.status == Self.notFoundStatus: return .failure(.itemNotFound)
            case .success(let r): return .failure(.readFailed(exitCode: r.status))
            case .failure(let f): return .failure(f)
            }
        case .success(let r):
            return .failure(.readFailed(exitCode: r.status))
        case .failure(let f):
            return .failure(f)
        }
        let content = Self.trimmed(output)
        if content.isEmpty { return .failure(.emptyItem) }
        guard let credentials = Self.parse(content) else { return .failure(.unrecognizedFormat) }
        return .success(credentials)
    }

    // MARK: - 解析

    /// 先按 JSON，失败再按十六进制解码后的 JSON
    static func parse(_ content: [UInt8]) -> OAuthCredentials? {
        if let c = OAuthCredentials(json: Data(content)) { return c }
        guard let decoded = decodeHex(content) else { return nil }
        return OAuthCredentials(json: Data(decoded))
    }

    private static func decodeHex(_ chars: [UInt8]) -> [UInt8]? {
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        return bytes
    }

    /// 去掉首尾的空白和换行（security -w 会在结尾加一个 \n）
    private static func trimmed(_ data: Data) -> [UInt8] {
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        var bytes = [UInt8](data)
        while let last = bytes.last, isSpace(last) { bytes.removeLast() }
        let start = bytes.firstIndex { !isSpace($0) } ?? bytes.endIndex
        return Array(bytes[start...])
    }

    // MARK: - 子进程

    /// security 表示"找不到"的退出码（errSecItemNotFound）
    private static let notFoundStatus: Int32 = 44

    private struct RunResult {
        let status: Int32
        let stdout: Data
    }

    private final class OutputBox {
        var data = Data()
    }

    private func run(_ arguments: [String]) -> Result<RunResult, CredentialReadFailure> {
        let process = Process()
        process.executableURL = environment.security
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.readFailed(exitCode: nil))
        }

        // 边运行边读 stdout，避免输出较多时子进程因管道写满而卡住
        let box = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = reader.readDataToEndOfFile()
            readDone.signal()
        }

        let deadline = DispatchTime.now() + environment.securityTimeout
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return .failure(.timedOut)
        }
        // 子进程已结束；它的后代若还占着管道，也不再等
        guard readDone.wait(timeout: .now() + 1) == .success else { return .failure(.timedOut) }
        return .success(RunResult(status: process.terminationStatus, stdout: box.data))
    }
}
