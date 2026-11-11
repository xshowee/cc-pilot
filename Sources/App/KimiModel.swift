// Kimi Code 账号的界面状态（ADR 0007）：账号名称列表（决定面板有没有 Kimi Code 一段、有几张卡片）、添加、删除。
// 一个账号 = 用户起的名称 + 一个 API key。key 不保存在这里：添加时直接交给 KimiKeyStore（钥匙串），之后只在
// 刷新额度和用户点"复制 API key"时才读。
// 复制（copyKey）：在后台读 key（可能弹出钥匙串授权，不能卡住界面），写进剪贴板（SecretClipboard：只留本机、
// 标记为机密和临时），SecretClipboard.clearAfter 秒后或 App 退出时，剪贴板仍是这次写入的内容就清空。
// 卡片上短暂显示复制成功或失败（copyNotice）。
// names 只查钥匙串项的名称（不读内容），启动时查一次，打开面板时重查。
// 添加入口是面板底栏的"添加账号…"（AddProfileForm 里选 Kimi Code）；删除入口在卡片上，先在面板里确认
// （KimiRemovalBanner）——key 只在创建时显示一次，删了要去控制台重新生成。
// 删除后让 UsageModel 忘掉这个账号的额度。添加后不自动请求额度：刷新永远由用户手动触发。
// 套餐有效期（KimiExpiry.swift）：用户在卡片上填，按账号名称存在 UserDefaults（不是机密，不进钥匙串），
// 删除账号时一起删；添加账号时也清掉同名的旧值（可能是上一次删除没清干净留下的）。
// editingExpiry 是正在编辑有效期的账号（面板底栏上方显示编辑条 KimiExpiryBanner）。

import AppKit

@MainActor
final class KimiModel: ObservableObject {
    @Published private(set) var names: [String]
    /// 等待确认删除的账号名称（面板显示确认条）
    @Published var confirmingRemoval: String?
    /// 各账号的套餐有效期（用户填的）；没填的账号没有
    @Published private(set) var expiries: [String: KimiExpiryDate]
    /// 正在编辑有效期的账号名称（面板显示编辑条）
    @Published var editingExpiry: String?
    /// 最近一次添加失败（钥匙串拒绝写入）；添加表单据此提示
    @Published var addFailed = false
    /// 最近一次复制 key 的结果（卡片上短暂显示）
    @Published private(set) var copyNotice: CopyNotice?

    struct CopyNotice: Equatable {
        let name: String
        let copied: Bool
    }

    /// UserDefaults 键：[账号名称: "yyyy-MM-dd"]
    static let expiriesKey = "kimiExpiryDates"

    /// 卡片上的复制结果显示多久
    static let noticeDuration: TimeInterval = 4

    private let store: KimiKeyStore
    private let usage: UsageModel
    private let clipboard = SecretClipboard(pasteboard: SystemSecretPasteboard())
    /// 最近一次复制的凭证（还没清除时）
    private var copiedToken: Int?
    /// 每次复制加一：过期的清除、隐藏提示不生效
    private var copyGeneration = 0
    private var terminationObserver: NSObjectProtocol?

    init(environment: CoreEnvironment = .live, usage: UsageModel) {
        store = environment.kimiKeys
        self.usage = usage
        names = store.names()
        let stored = UserDefaults.standard.dictionary(forKey: Self.expiriesKey) as? [String: String] ?? [:]
        expiries = stored.compactMapValues(KimiExpiryDate.init(string:))
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearCopiedKey() }
        }
    }

    var isVisible: Bool { !names.isEmpty }

    func reload() {
        let stored = store.names()
        if stored != names { names = stored }
        if let pending = confirmingRemoval, !stored.contains(pending) { confirmingRemoval = nil }
        if let editing = editingExpiry, !stored.contains(editing) { editingExpiry = nil }
    }

    /// 设置或清除（nil）这个账号的有效期
    func setExpiry(_ expiry: KimiExpiryDate?, for name: String) {
        expiries[name] = expiry
        UserDefaults.standard.set(expiries.mapValues(\.string), forKey: Self.expiriesKey)
    }

    func problem(forNewName name: String) -> ProfileCommands.NewNameProblem? {
        KimiAccountName.problem(name, existing: names)
    }

    /// 添加账号：名称或 key 有问题时什么都不做，返回 false；钥匙串写入失败时 addFailed 为 true，返回 false
    @discardableResult
    func add(_ name: String, key input: String) -> Bool {
        guard problem(forNewName: name) == nil, let key = KimiAccountName.normalizedKey(input) else { return false }
        do {
            try store.save(key, for: name)
        } catch {
            NSLog("CC Pilot: 无法保存 Kimi Code API key：%@", String(describing: error))
            addFailed = true
            return false
        }
        addFailed = false
        usage.forgetKimi(name)
        if expiries[name] != nil { setExpiry(nil, for: name) }
        reload()
        return true
    }

    /// 把这个账号的 key 复制到剪贴板（见文件头）
    func copyKey(_ name: String) {
        copyGeneration += 1
        let generation = copyGeneration
        let store = self.store
        Task {
            let key = await Task.detached(priority: .userInitiated) { store.read(name) }.value
            guard generation == copyGeneration else { return }
            if let key {
                copiedToken = clipboard.copy(key)
            }
            copyNotice = CopyNotice(name: name, copied: key != nil)
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000))
            if generation == copyGeneration { copyNotice = nil }
            guard key != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64((SecretClipboard.clearAfter - Self.noticeDuration) * 1_000_000_000))
            if generation == copyGeneration { clearCopiedKey() }
        }
    }

    /// 剪贴板仍是最近一次复制的 key 时清空
    private func clearCopiedKey() {
        guard let token = copiedToken else { return }
        clipboard.clearIfUnchanged(since: token)
        copiedToken = nil
    }

    /// 删除账号（已确认）：从钥匙串移除 key，忘掉它的额度
    func remove(_ name: String) {
        do {
            try store.remove(name)
        } catch {
            NSLog("CC Pilot: 无法移除 Kimi Code API key：%@", String(describing: error))
        }
        usage.forgetKimi(name)
        setExpiry(nil, for: name)
        confirmingRemoval = nil
        reload()
    }
}
