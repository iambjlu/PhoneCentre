import Foundation

/// 管理所有暫存（App 圖示、相片縮圖、預覽用下載檔），依使用者設定的容量上限與清除時機清理。
/// 結構：~/Library/Caches/PhoneCentre/<裝置鍵>/{icons,thumbs,files}
@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    @Published private(set) var totalBytes: Int64 = 0

    let root: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneCentre", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private var lastSeenFile: URL { root.appendingPathComponent("last-seen.json") }
    private var lastSeen: [String: Date] = [:]
    private var timer: Timer?
    private var onlineKeys: Set<String> = []

    private init() {
        if let raw = try? Data(contentsOf: lastSeenFile),
           let v = try? JSONDecoder().decode([String: Date].self, from: raw) { lastSeen = v }
    }

    /// 裝置的快取鍵：優先使用 ro.serialno，換 port 或換連線方式都不變
    nonisolated static func key(for device: Device) -> String {
        let raw = device.info?.serialNo.isEmpty == false ? device.info!.serialNo : device.serial
        return raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    func dir(_ device: Device, _ kind: String) -> URL {
        let u = root.appendingPathComponent(Self.key(for: device), isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func start() {
        guard timer == nil else { return }
        enforce()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforce() }
        }
    }

    /// DeviceManager 每次更新裝置清單時呼叫
    func devicesChanged(_ devices: [Device]) {
        let now = Set(devices.filter(\.isOnline).map(Self.key(for:)))
        for k in now { lastSeen[k] = Date() }
        let gone = onlineKeys.subtracting(now)
        onlineKeys = now
        if !gone.isEmpty, AppSettings.shared.cacheClearPolicy == .onDisconnect {
            for k in gone { try? FileManager.default.removeItem(at: root.appendingPathComponent(k)) }
            recalc()
        }
        saveLastSeen()
    }

    private func saveLastSeen() {
        if let raw = try? JSONEncoder().encode(lastSeen) { try? raw.write(to: lastSeenFile) }
    }

    /// 套用清除時機與容量上限
    func enforce() {
        let s = AppSettings.shared
        let fm = FileManager.default
        if s.cacheClearPolicy == .afterDays {
            let limit = Date().addingTimeInterval(-Double(max(s.cacheClearDays, 1)) * 86_400)
            for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where dir.hasDirectoryPath {
                let k = dir.lastPathComponent
                if onlineKeys.contains(k) { continue }
                if (lastSeen[k] ?? .distantPast) < limit {
                    try? fm.removeItem(at: dir)
                    lastSeen[k] = nil
                }
            }
            saveLastSeen()
        }
        trim(toBytes: Int64(max(s.cacheLimitMB, 10)) * 1_048_576)
    }

    /// 依最後使用時間（LRU）刪除，直到低於上限
    private func trim(toBytes limit: Int64) {
        let root = root
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentAccessDateKey]
            var files: [(URL, Int64, Date)] = []
            var total: Int64 = 0
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) {
                for case let u as URL in e {
                    guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    if u.lastPathComponent == "last-seen.json" { continue }
                    let size = Int64(v.totalFileAllocatedSize ?? 0)
                    total += size
                    files.append((u, size, v.contentAccessDate ?? .distantPast))
                }
            }
            if total > limit {
                for f in files.sorted(by: { $0.2 < $1.2 }) {
                    try? fm.removeItem(at: f.0)
                    total -= f.1
                    if total <= limit * 9 / 10 { break }   // 多清一點，避免頻繁觸發
                }
            }
            let finalTotal = total
            await MainActor.run { CacheManager.shared.totalBytes = finalTotal }
        }
    }

    func recalc() { trim(toBytes: Int64(max(AppSettings.shared.cacheLimitMB, 10)) * 1_048_576) }

    func clearAll() {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: u)
        }
        lastSeen = [:]
        totalBytes = 0
    }
}
