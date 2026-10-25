import AppKit
import Foundation

struct AppEntry: Identifiable, Hashable {
    var package: String
    var label: String
    var isSystem: Bool
    var id: String { package }
}

/// 一台裝置上的 App 清單、圖示，以及執行中／最近使用的 App
@MainActor
final class AppCatalog: ObservableObject {
    var device: Device

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var running: [String] = []     // 已開啟（有程序在跑）的 App，依最近使用排序
    @Published private(set) var foreground: String?         // 目前在手機畫面最上層的 App（桌面、系統介面不算）
    @Published private(set) var recent: [String] = []      // 最近用過但已不在執行
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private var iconRequests: Set<String> = []
    private var homePackage: String?
    private var installed: Set<String> = []


    init(device: Device) { self.device = device }

    func label(for pkg: String) -> String {
        apps.first { $0.package == pkg }?.label ?? pkg.split(separator: ".").last.map(String.init) ?? pkg
    }

    private func helper(_ args: [String], timeout: TimeInterval = 60) async throws -> String {
        try await HelperTool.shared.run(device, args, timeout: timeout)
    }

    // MARK: App 清單

    func reload() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            let out = try await helper(["list"])
            var list: [AppEntry] = out.split(separator: "\n").compactMap { line in
                let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard p.count >= 3 else { return nil }
                return AppEntry(package: p[0], label: p[1], isSystem: p[2] == "1")
            }
            if list.isEmpty {
                // 輔助程式失敗時的備援：只有套件名稱
                let out2 = try await device.client.shell(
                    "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER")
                let pkgs = Set(out2.split(separator: "\n").compactMap { l -> String? in
                    let s = l.trimmingCharacters(in: .whitespaces)
                    guard s.contains("/") else { return nil }
                    return String(s.split(separator: "/")[0])
                })
                list = pkgs.map { AppEntry(package: $0, label: $0.split(separator: ".").last.map(String.init) ?? $0, isSystem: false) }
            }
            apps = list.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            loadIcons(apps.map(\.package))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: 圖示

    private var iconDir: URL { CacheManager.shared.dir(device, "icons") }

    /// 在 view body 中呼叫也安全：不會同步修改 @Published
    private var diskMemo: [String: NSImage] = [:]
    func icon(for pkg: String) -> NSImage? {
        if let i = icons[pkg] ?? diskMemo[pkg] { return i }
        let f = iconDir.appendingPathComponent("\(pkg).png")
        if let img = NSImage(contentsOf: f) {
            diskMemo[pkg] = img
            return img
        }
        Task { @MainActor in self.loadIcons([pkg]) }
        return nil
    }

    func loadIcons(_ pkgs: [String], force: Bool = false) {
        var need: [String] = []
        for p in pkgs where icons[p] == nil && !iconRequests.contains(p) {
            let f = iconDir.appendingPathComponent("\(p).png")
            if !force, let img = NSImage(contentsOf: f) { icons[p] = img; continue }
            need.append(p)
        }
        guard !need.isEmpty else { return }
        iconRequests.formUnion(need)
        Task {
            // 分批，避免指令列過長
            for chunk in stride(from: 0, to: need.count, by: 40).map({ Array(need[$0..<min($0 + 40, need.count)]) }) {
                guard let out = try? await helper(["icons", "128"] + chunk, timeout: 120) else { continue }
                for line in out.split(separator: "\n") {
                    let p = line.split(separator: "\t").map(String.init)
                    guard p.count == 2, let data = Data(base64Encoded: p[1]), let img = NSImage(data: data) else { continue }
                    try? data.write(to: iconDir.appendingPathComponent("\(p[0]).png"))
                    icons[p[0]] = img
                }
            }
        }
    }

    // MARK: 執行中／最近

    func refreshTasks() async {
        if homePackage == nil {
            let h = (try? await device.client.shell(
                "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1")) ?? ""
            homePackage = h.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        if installed.isEmpty {
            let out = (try? await device.client.shell("pm list packages")) ?? ""
            installed = Set(out.split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        }
        guard let out = try? await device.client.shell(
            "dumpsys activity recents; echo '@@PS@@'; ps -A -o NAME; echo '@@FG@@'; dumpsys activity activities | grep -m1 -E 'topResumedActivity=|mResumedActivity:'") else { return }
        let fgParts = out.components(separatedBy: "@@FG@@")
        let halves = fgParts[0].components(separatedBy: "@@PS@@")
        // 「…ActivityRecord{3f2a0 u0 com.instagram.android/.MainActivity t12…}」→ com.instagram.android
        var fg: String?
        if fgParts.count > 1, let r = fgParts[1].range(of: #"u\d+ [A-Za-z0-9_.]+/"#, options: .regularExpression) {
            fg = fgParts[1][r].split(separator: " ").last.map { String($0.dropLast()) }
        }
        if let f = fg, f == homePackage || f == "com.android.systemui" { fg = nil }
        if fg != foreground { foreground = fg }
        let procs = Set((halves.count > 1 ? halves[1] : "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var order: [String] = []
        for pkg in Self.parseRecents(halves[0], installed: installed)
        where pkg != homePackage && pkg != "com.android.systemui" && !order.contains(pkg) {
            order.append(pkg)
        }
        var run = order.filter { procs.contains($0) }
        // 不在「最近使用」裡的 App（例如通訊功能設定這類排除在最近使用之外的）只要它在最上層，就一定是執行中
        if let fg, !run.contains(fg) { run.insert(fg, at: 0) }
        let rec = Array(order.filter { !procs.contains($0) && $0 != fg }.prefix(12))
        if run != running { running = run }
        if rec != recent { recent = rec }
        loadIcons(run + rec)
    }

    /// 解析 dumpsys activity recents：每個「Recent #N」區塊找 realActivity／cmp=，
    /// 找不到時用 affinity（A=uid:affinity）對已安裝套件做前綴比對（例如 com.android.settings.root）。
    nonisolated static func parseRecents(_ text: String, installed: Set<String>) -> [String] {
        var result: [String] = []
        var blocks: [[Substring]] = []
        var inBlock = false
        for line in text.split(separator: "\n") {
            if line.contains("* Recent #") {
                blocks.append([line]); inBlock = true
            } else if inBlock, line.hasPrefix("    "), !line.contains("RecentTaskInfo") {
                blocks[blocks.count - 1].append(line)
            } else {
                inBlock = false   // 後面的「Visible recent tasks」等段落不屬於任何區塊
            }
        }
        for block in blocks {
            let header = block[0]
            if header.contains("type=home") || header.contains("type=recents") || header.contains("type=assistant") { continue }
            var pkg: String?
            for l in block.dropFirst() {
                if let r = l.range(of: "realActivity={") ?? l.range(of: "realActivity=") ?? l.range(of: "cmp=") {
                    let rest = l[r.upperBound...]
                    if let slash = rest.firstIndex(of: "/") { pkg = String(rest[..<slash]); break }
                }
            }
            if pkg == nil, let r = header.range(of: " A=") {
                var aff = String(header[r.upperBound...].prefix { $0 != " " })
                if let colon = aff.firstIndex(of: ":") { aff = String(aff[aff.index(after: colon)...]) }
                var comps = aff.split(separator: ".").map(String.init)
                while comps.count >= 2 {
                    let cand = comps.joined(separator: ".")
                    if installed.isEmpty || installed.contains(cand) { pkg = cand; break }
                    comps.removeLast()
                }
            }
            if let pkg { result.append(pkg) }
        }
        return result
    }

    // MARK: 操作

    /// 在指定 display 上啟動 App（nil = 主螢幕）
    func launch(_ pkg: String, displayId: Int? = nil) async {
        let comp = (try? await device.client.shell(
            "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \(pkg) | tail -1"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = displayId.map { " --display \($0)" } ?? ""
        if comp.contains("/") {
            _ = try? await device.client.shell("am start\(display) -n \(comp)")
        } else {
            _ = try? await device.client.shell("monkey -p \(pkg) -c android.intent.category.LAUNCHER 1")
        }
    }

    func forceStop(_ pkg: String) async {
        _ = try? await device.client.shell("am force-stop \(pkg)")
        await refreshTasks()
    }

    func uninstall(_ pkg: String) async -> String {
        let r = (try? await device.client.shell("pm uninstall --user 0 \(pkg)")) ?? ""
        await reload()
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openAppInfo(_ pkg: String) async {
        _ = try? await device.client.shell("am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:\(pkg)")
    }
}

extension AppCatalog {
    /// App 列、總覽、啟動台共用的排序：已開啟的在前（目前在最上層的 → 已開啟的喜好項目 → 其他已開啟的），
    /// 還沒開的喜好項目在後（兩組中間畫分隔線）
    func barOrder(pins: [String]) -> (opened: [String], unopened: [String]) {
        let cur = foreground
        let run = running
        let opened = (cur.map { [$0] } ?? [])
            + pins.filter { run.contains($0) && $0 != cur }
            + run.filter { !pins.contains($0) && $0 != cur }
        let unopened = pins.filter { !run.contains($0) && $0 != cur }
        return (opened, unopened)
    }
}
