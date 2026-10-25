import AppKit
import Foundation
import SwiftUI

/// Dock 顯示方式
enum DockMode: String, CaseIterable, Identifiable, Codable {
    case shared      // 整個 PhoneCentre 共用一個 Dock 圖示
    case separate    // 每個視窗在 Dock 上獨立一個圖示（以獨立程序執行）
    var id: String { rawValue }
    var title: String { self == .shared ? "整個程式共用一個" : "每個視窗各自一個" }
}

/// 從啟動台開啟 App 的方式
enum AppLaunchTarget: String, CaseIterable, Identifiable, Codable {
    case mainDisplay       // 在手機主螢幕開啟（鏡像視窗會顯示）
    case separateWindow    // 在虛擬顯示器上開啟，Mac 端是獨立視窗（類似「連結至 Windows」）
    var id: String { rawValue }
    var title: String { self == .mainDisplay ? "在手機主螢幕開啟" : "在獨立視窗開啟" }
}

/// 鍵盤輸入模式
enum KeyboardMode: String, CaseIterable, Identifiable, Codable {
    case physical   // 依實體按鍵位置送 Android keycode，不受 Mac 輸入法影響
    case macIME     // 使用 Mac 輸入法組字，送出確定的文字
    var id: String { rawValue }
    var title: String { self == .physical ? "實體按鍵" : "Mac 輸入法" }
}

/// 快取清除時機
enum CacheClearPolicy: String, CaseIterable, Identifiable, Codable {
    case onDisconnect   // 裝置斷線就清除該裝置的快取
    case afterDays      // 裝置幾天沒連線才清除
    case never          // 只受容量上限限制
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDisconnect: return "裝置斷線時立即清除"
        case .afterDays: return "裝置幾天沒連線後清除"
        case .never: return "只依容量上限清除"
        }
    }
}

struct VideoOptions: Codable, Equatable {
    var maxFps: Int = 60
    var bitRateMbps: Double = 8
    var maxSize: Int = 1920     // 0 = 不限制
}

/// 所有可同步的設定（存在 UserDefaults 或使用者指定資料夾的 settings.json）
struct SettingsData: Codable, Equatable {
    var keepAlive = true
    var rememberWireless = true
    var mirrorDockMode: DockMode = .shared
    var appWindowDockMode: DockMode = .separate
    var launchTarget: AppLaunchTarget = .separateWindow
    var keyboardMode: KeyboardMode = .macIME
    var video = VideoOptions()
    var perDeviceVideo: [String: VideoOptions] = [:]
    var audioEnabled = true
    var muteDeviceWhenForwarding = true
    var clipboardSync = true
    var turnScreenOffWhileMirroring = false
    var desktopModeForAppWindows = false
    var showMenuBarIcon = true
    var shareEnabled = false
    var sharePort = 47_500
    var savedEndpoints: [SavedEndpoint] = []
    var remoteHosts: [RemoteHost] = []
    var cacheLimitMB = 200
    var cacheClearPolicy: CacheClearPolicy = .afterDays
    var cacheClearDays = 7
    var offerTouchIDUnlock = true
    /// 透過 adb 收集並保存簡訊、通知、通話記錄
    var phoneDataEnabled = false
    /// 各類資料保存幾天（0 = 永久）
    var smsRetentionDays = 30
    var callRetentionDays = 30
    var notificationRetentionDays = 30
    /// 每台裝置（CacheManager.key）釘選的 App 套件名稱，依釘選順序
    var pinnedApps: [String: [String]] = [:]
    /// 密碼類資料也寫進同步資料夾（明碼）
    var syncSecrets = false
    var secrets: [String: String] = [:]
}

/// 全域設定。用 dynamicMemberLookup 讓 `settings.keepAlive` 直接讀寫 `data.keepAlive`。
@dynamicMemberLookup
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// 固定的 suite：Dock 獨立視窗的子程序 bundle id 不同，也要讀到同一份設定
    private let d = UserDefaults(suiteName: "com.iambjlu.PhoneCentre.shared")!

    @Published var data: SettingsData {
        didSet { if data != oldValue { persist() } }
    }

    // 以下只存在本機（不同步）
    @Published var customAdbPath: String { didSet { d.set(customAdbPath, forKey: "customAdbPath") } }
    /// 設定檔資料夾；nil = 存在本機 UserDefaults
    @Published private(set) var settingsFolder: URL?

    private var lastFileDate: Date?
    /// 最後一次寫入或讀進來的 UserDefaults 內容：用來發現「另一個程序」（主程式與 Dock 獨立視窗各是一個程序）改了設定
    private var lastSuiteRaw: Data?
    private var suiteTimer: Timer?
    private var watchTimer: Timer?

    subscript<T>(dynamicMember kp: WritableKeyPath<SettingsData, T>) -> T {
        get { data[keyPath: kp] }
        set { data[keyPath: kp] = newValue }
    }

    private init() {
        customAdbPath = d.string(forKey: "customAdbPath") ?? ""
        // 子程序（Dock 獨立視窗）不讀寫設定資料夾，只用主程式寫在 UserDefaults suite 的那份，
        // 這樣 iCloud Drive 等資料夾的存取權限只會由主程式詢問一次
        settingsFolder = ChildMode.isChild ? nil : d.string(forKey: "settingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        data = SettingsData()
        data = loadData() ?? SettingsData()
        lastSuiteRaw = d.data(forKey: "settings")
        startWatching()
        startSuiteWatching()
    }

    // MARK: 釘選 App

    func pinned(for device: Device) -> [String] { data.pinnedApps[CacheManager.key(for: device)] ?? [] }

    func isPinned(_ pkg: String, on device: Device) -> Bool { pinned(for: device).contains(pkg) }

    func togglePin(_ pkg: String, on device: Device) {
        let k = CacheManager.key(for: device)
        var list = data.pinnedApps[k] ?? []
        if let i = list.firstIndex(of: pkg) { list.remove(at: i) } else { list.append(pkg) }
        data.pinnedApps[k] = list
    }

    // MARK: 存取

    private var settingsFile: URL? { settingsFolder?.appendingPathComponent("settings.json") }

    /// 讀檔時以預設值補齊缺少的欄位（舊版設定檔也能讀）
    private static func decodeMerged(_ raw: Data) -> SettingsData? {
        guard let loaded = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let defData = try? JSONEncoder().encode(SettingsData()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return nil }
        let merged = defaults.merging(loaded) { $1 }
        guard let m = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(SettingsData.self, from: m)
    }

    private func loadData() -> SettingsData? {
        if let f = settingsFile {
            lastFileDate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let raw = try? Data(contentsOf: f) { return Self.decodeMerged(raw) }
        }
        return d.data(forKey: "settings").flatMap(Self.decodeMerged)
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var out = data
        if !out.syncSecrets { out.secrets = [:] }
        guard let raw = try? enc.encode(out) else { return }
        d.set(raw, forKey: "settings")
        lastSuiteRaw = raw
        if let f = settingsFile {
            try? raw.write(to: f, options: .atomic)
            lastFileDate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// 偵測其他程序改了設定：在 Dock 獨立視窗（另一個程序）裡加入的喜好項目等，主程式要馬上看得到，
    /// 反過來也一樣；否則兩邊各存各的，後存的還會蓋掉先存的
    private func startSuiteWatching() {
        suiteTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let raw = self.d.data(forKey: "settings"), raw != self.lastSuiteRaw else { return }
            self.lastSuiteRaw = raw
            guard var new = Self.decodeMerged(raw), new != self.data else { return }
            if !new.syncSecrets { new.secrets = self.data.secrets }
            self.data = new
        }
    }

    /// 偵測其他電腦透過 iCloud 改了設定檔
    private func startWatching() {
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, let f = self.settingsFile else { return }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let date, date != self.lastFileDate else { return }
            self.lastFileDate = date
            if let raw = try? Data(contentsOf: f), let new = Self.decodeMerged(raw), new != self.data {
                var merged = new
                // 對方沒同步密碼時保留本機的
                if !merged.syncSecrets { merged.secrets = self.data.secrets }
                self.data = merged
            }
        }
    }

    /// 改變設定檔位置；會把目前設定寫到新位置（若新位置已有設定檔則改為讀取它）
    func setSettingsFolder(_ url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            d.set(url.path, forKey: "settingsFolder")
        } else {
            d.removeObject(forKey: "settingsFolder")
        }
        settingsFolder = url
        if let f = settingsFile, let raw = try? Data(contentsOf: f), let existing = Self.decodeMerged(raw) {
            data = existing
        } else {
            persist()
        }
    }

    static var iCloudDriveURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    // MARK: 影像設定

    func videoOptions(for key: String) -> VideoOptions { data.perDeviceVideo[key] ?? data.video }
    func setVideoOptions(_ o: VideoOptions, for key: String) { data.perDeviceVideo[key] = o }

    // MARK: 密碼（鑰匙圈；開啟同步時也寫入設定檔）

    func secret(_ key: String) -> String? {
        if let v = Keychain.get(key), !v.isEmpty { return v }
        if let v = data.secrets[key], !v.isEmpty {
            Keychain.set(key, v)   // 從同步資料夾取得後存回本機鑰匙圈
            return v
        }
        return nil
    }

    func setSecret(_ key: String, _ value: String?) {
        Keychain.set(key, value ?? "")
        if let value, !value.isEmpty { data.secrets[key] = value } else { data.secrets[key] = nil }
        objectWillChange.send()
    }

    var sharePassword: String {
        get { secret("sharePassword") ?? "" }
        set { setSecret("sharePassword", newValue) }
    }
}

/// 記住的無線 ADB 端點
struct SavedEndpoint: Codable, Hashable, Identifiable {
    var address: String          // host:port
    var serialNo: String?        // ro.serialno，用來在 port 變動時透過 mDNS 找回
    var name: String?
    var id: String { address }
}

/// 遠端 PhoneCentre 主機
struct RemoteHost: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var autoConnect: Bool = true
    var secretKey: String { "remote.\(id.uuidString)" }
}
