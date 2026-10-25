import Foundation

/// 尋找 adb 執行檔；找不到時可協助從 Google 官方下載 platform-tools
enum AdbLocator {
    static let platformToolsURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneCentre", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var managedAdb: URL { supportDir.appendingPathComponent("platform-tools/adb") }

    /// 依序：自訂路徑 → PhoneCentre 下載的 → Android SDK → Homebrew → PATH
    static func find() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        let custom = AppSettings.shared.customAdbPath
        if !custom.isEmpty { candidates.append(custom) }
        candidates.append(managedAdb.path)
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] { candidates.append("\(home)/platform-tools/adb") }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/adb")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// 下載並解壓 platform-tools，回傳 adb 路徑
    static func install(progress: @escaping (String) -> Void) async throws -> String {
        progress("正在從 Google 下載 Android SDK Platform-Tools…")
        let (tmp, response) = try await URLSession.shared.download(from: platformToolsURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "PhoneCentre", code: 1, userInfo: [NSLocalizedDescriptionKey: "下載失敗"])
        }
        progress("正在解壓縮…")
        let dest = supportDir
        try? FileManager.default.removeItem(at: dest.appendingPathComponent("platform-tools"))
        let r = try await Shell.run("/usr/bin/ditto", ["-x", "-k", tmp.path, dest.path])
        guard r.status == 0, FileManager.default.isExecutableFile(atPath: managedAdb.path) else {
            throw NSError(domain: "PhoneCentre", code: 2, userInfo: [NSLocalizedDescriptionKey: "解壓縮失敗：\(r.stderr)"])
        }
        // 移除隔離屬性，避免 Gatekeeper 擋下
        _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.appendingPathComponent("platform-tools").path])
        progress("安裝完成")
        return managedAdb.path
    }
}
