import Foundation

/// 簡訊、通知、通話記錄的本機保存與定時收集（全程用 adb shell，不在手機安裝任何東西）。
/// 儲存在 ~/Library/Application Support/PhoneCentre/Data/<裝置鍵>/data.json（不放快取目錄，不會被容量清理刪掉）。
@MainActor
final class PhoneDataStore: ObservableObject {
    static let shared = PhoneDataStore()

    /// 資料有變動就加 1，讓 SwiftUI 重新讀取
    @Published private(set) var revision = 0
    @Published private(set) var syncing: Set<String> = []

    private var bundles: [String: PhoneDataBundle] = [:]
    private var tickCount = 0
    private var timer: Timer?

    private let root: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneCentre/Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private func file(_ key: String) -> URL {
        root.appendingPathComponent(key, isDirectory: true).appendingPathComponent("data.json")
    }

    func bundle(for device: Device) -> PhoneDataBundle { load(CacheManager.key(for: device)) }

    private func load(_ key: String) -> PhoneDataBundle {
        if let b = bundles[key] { return b }
        let b = (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(PhoneDataBundle.self, from: $0) } ?? PhoneDataBundle()
        bundles[key] = b
        return b
    }

    private func save(_ key: String, _ b: PhoneDataBundle) {
        bundles[key] = b
        let f = file(key)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let raw = try? JSONEncoder().encode(b) { try? raw.write(to: f, options: .atomic) }
        revision += 1
    }

    /// 刪除這台裝置所有已保存的資料
    func deleteAll(for device: Device) {
        let key = CacheManager.key(for: device)
        bundles[key] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key))
        revision += 1
    }

    // MARK: 保存期限

    /// 0 = 永久
    private func cutoff(_ days: Int) -> Date? { days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil }

    /// 依設定刪掉超過保存期限的資料（還在手機上的通知不刪）
    func prune() {
        let s = AppSettings.shared
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where dir.hasDirectoryPath {
            let key = dir.lastPathComponent
            var b = load(key)
            let before = (b.sms.count, b.calls.count, b.notifications.count)
            if let c = cutoff(s.smsRetentionDays) { b.sms.removeAll { $0.date < c } }
            if let c = cutoff(s.callRetentionDays) { b.calls.removeAll { $0.date < c } }
            if let c = cutoff(s.notificationRetentionDays) { b.notifications.removeAll { $0.isActive == false && $0.firstSeen < c } }
            if (b.sms.count, b.calls.count, b.notifications.count) != before { save(key, b) }
        }
    }

    // MARK: 定時收集

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        prune()
    }

    private func tick() {
        guard AppSettings.shared.phoneDataEnabled else { return }
        tickCount += 1
        // 通知每 15 秒；簡訊與通話記錄每分鐘
        let full = tickCount % 4 == 1
        for d in DeviceManager.shared.onlineDevices where d.info != nil {
            Task { await sync(d, messagesAndCalls: full) }
        }
        if tickCount % 240 == 0 { prune() }
    }

    /// 立刻同步一台裝置（UI 的「立即更新」也走這裡）
    func sync(_ device: Device, messagesAndCalls: Bool = true) async {
        let key = CacheManager.key(for: device)
        guard !syncing.contains(key) else { return }
        syncing.insert(key)
        defer { syncing.remove(key) }
        let s = AppSettings.shared
        let c = device.client

        // 簡訊與通話記錄：只抓比已保存最新一筆更新的
        var newSMS: [PhoneSMS] = [], newCalls: [PhoneCall] = []
        if messagesAndCalls {
            let b = load(key)
            let smsFrom = max(b.sms.map(\.date).max()?.timeIntervalSince1970 ?? 0,
                              cutoff(s.smsRetentionDays)?.timeIntervalSince1970 ?? 0)
            let callFrom = max(b.calls.map(\.date).max()?.timeIntervalSince1970 ?? 0,
                               cutoff(s.callRetentionDays)?.timeIntervalSince1970 ?? 0)
            if let out = try? await c.shell(Self.query("content://sms", PhoneDataParser.smsKeys, since: smsFrom), timeout: 90) {
                newSMS = PhoneDataParser.sms(out)
            }
            if let out = try? await c.shell(Self.query("content://call_log/calls", PhoneDataParser.callKeys, since: callFrom), timeout: 60) {
                newCalls = PhoneDataParser.calls(out)
            }
        }
        let dump = try? await c.shell("dumpsys notification --noredact", timeout: 30)
        let active = dump.flatMap(PhoneDataParser.notifications)

        var b = load(key)
        let existingSMS = Set(b.sms.map(\.id)), existingCalls = Set(b.calls.map(\.id))
        b.sms += newSMS.filter { !existingSMS.contains($0.id) }
        b.calls += newCalls.filter { !existingCalls.contains($0.id) }
        if let active { merge(active, into: &b.notifications) }
        if messagesAndCalls || active != nil { b.lastSync = Date() }
        save(key, b)
        if !newSMS.isEmpty || !newCalls.isEmpty { prune() }
    }

    /// 重新對照手機上目前的通知：不見的標成已清除、新出現的加入、內容改變的更新
    private func merge(_ active: [PhoneDataParser.ActiveNotification], into list: inout [PhoneNotification]) {
        let now = Date()
        let keys = Set(active.map(\.key))
        for i in list.indices where list[i].isActive && !keys.contains(list[i].key) { list[i].clearedAt = now }
        for a in active {
            if let i = list.firstIndex(where: { $0.isActive && $0.key == a.key }) {
                list[i].title = a.title
                list[i].text = a.text
                list[i].ongoing = a.ongoing
            } else {
                list.append(PhoneNotification(id: "\(a.key)#\(Int(now.timeIntervalSince1970 * 1000))", key: a.key,
                                              package: a.package, title: a.title, text: a.text,
                                              ongoing: a.ongoing, firstSeen: now, clearedAt: nil))
            }
        }
    }

    private static func query(_ uri: String, _ keys: [String], since: TimeInterval) -> String {
        var cmd = "content query --uri \(uri) --projection \(keys.joined(separator: ":"))"
        if since > 0 { cmd += " --where " + Shell.quote("date>\(Int64(since * 1000))") }
        return cmd + " --sort 'date ASC'"
    }
}
