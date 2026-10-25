import SwiftUI
import UniformTypeIdentifiers

struct DeviceOverview: View {
    let device: Device
    @State private var storage = ""
    @State private var status = DeviceStatus()
    /// 手機狀態讀到之前，相關欄位只轉圈圈，不顯示預設的錯誤資訊（例如「沒有 SIM 卡」「未連線」）
    @State private var statusLoaded = false
    @State private var storageLoaded = false
    @State private var showPassword = false
    @State private var showSerial = false
    @State private var message = ""
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Button { WindowManager.shared.openMirror(device) } label: {
                        Image(systemName: "iphone.gen3").font(.system(size: 56)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("開啟鏡像畫面")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName).font(.title.bold())
                        Text(device.subtitle).foregroundStyle(.secondary)
                        Text(device.isRemote ? "透過遠端 PhoneCentre" : (device.isWireless ? "無線 · \(device.serial)" : "USB · \(device.serial)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                PinnedAppsStrip(device: device, catalog: DeviceManager.shared.catalog(for: device))

                HStack(spacing: 12) {
                    BigButton("鏡像畫面", "rectangle.on.rectangle") { WindowManager.shared.openMirror(device) }
                    BigButton("桌面模式(Beta)", "desktopcomputer") { WindowManager.shared.openDesktop(device) }
                    BigButton("安裝 APK…", "shippingbox") { pickAPK() }
                    BigButton("解鎖密碼…", "touchid") { showPassword = true }
                }

                GroupBox("裝置資訊") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("型號", device.info.map { "\($0.manufacturer) \($0.model)" } ?? device.model)
                        row("Android", device.info.map { "\($0.androidVersion)（API \($0.sdk)）" } ?? "—")
                        row("螢幕", device.info.map { "\($0.screenSize) · \($0.density) dpi" } ?? "—")
                        if !statusLoaded {
                            ForEach(["生產日期", "電信業者", "Wi-Fi", "電池", "電池容量", "循環次數"], id: \.self) { loadingRow($0) }
                        } else {
                            if let d = manufactureText { row("生產日期", d) }
                            if status.sims.count > 1 {
                                ForEach(status.sims, id: \.slot) { row("電信業者\($0.slot)", simText($0)) }
                            } else {
                                row("電信業者", carrierText)
                            }
                            row("Wi-Fi", wifiText)
                            row("電池", batteryText)
                            if let c = capacityText { row("電池容量", c) }
                            if let n = status.batteryCycles { row("循環次數", "\(n) 次") }
                        }
                        if storageLoaded { row("儲存空間", storage.isEmpty ? "—" : storage) } else { loadingRow("儲存空間") }
                        HStack(alignment: .top) {
                            Text("序號").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            Text(showSerial ? (device.info?.serialNo ?? device.serial) : "••••••••••").textSelection(.enabled)
                            Button { showSerial.toggle() } label: { Image(systemName: showSerial ? "eye.slash" : "eye") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(showSerial ? "隱藏序號" : "顯示序號")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.4))
                    .frame(height: 90)
                    .overlay(Text(message.isEmpty ? "把檔案拖到這裡：APK 會安裝、照片影片存到相機膠卷、其他存到下載" : message)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding())
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        loadURLs(providers) { urls in
                            Task { await DropHandler.handle(urls, device: device) { message = $0 } }
                        }
                        return true
                    }

            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)   // 捲動內容撐滿寬度，工具列後面的邊緣效果才不會只有 760 寬一塊
        }
        .task(id: device.id) {
            // 載入後每 10 秒更新一次（電池、訊號會變；手機剛開機、服務還沒起來時第一次可能失敗）
            while !Task.isCancelled {
                await loadStatus()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .sheet(isPresented: $showPassword) { LockPasswordSheet(device: device) }
    }

    private func loadingRow(_ k: String) -> some View {
        HStack(alignment: .center) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(v).textSelection(.enabled)
        }
    }

    private var manufactureText: String? {
        let d = status.manufactureDate
        guard d.count == 8, d.allSatisfy(\.isNumber) else { return nil }
        return "\(d.prefix(4))/\(d.dropFirst(4).prefix(2))/\(d.suffix(2))"
    }

    /// 不管 SIM 卡是哪家，只寫目前收到的電信：
    /// 正常服務「中華電信 LTE -106dBm」；只能撥緊急電話「僅限緊急通話 LTE -106dBm (中華電信)」
    private func simText(_ sim: SimInfo) -> String {
        if sim.powerOff { return "行動網路已關閉" }
        let signal = [sim.tech, sim.dbm.map { "\($0)dBm" }].compactMap { $0 }.filter { !$0.isEmpty }
        if sim.emergencyOnly && !sim.inService {
            let head = (["僅限緊急通話"] + signal).joined(separator: " ")
            return sim.carrier.isEmpty ? head : "\(head) (\(sim.carrier))"
        }
        let parts = (sim.carrier.isEmpty ? [] : [sim.carrier]) + signal
        return parts.isEmpty ? (sim.inService ? "—" : "沒有服務") : parts.joined(separator: " ")
    }

    private var carrierText: String {
        guard status.hasSim else { return "沒有 SIM 卡" }
        return simText(status.sims.first ?? SimInfo(carrier: status.carrier, tech: status.radioTech, dbm: status.signalDbm, inService: status.inService))
    }

    private var wifiText: String {
        guard !status.wifiSSID.isEmpty else { return "未連線" }
        return status.wifiIP.isEmpty ? status.wifiSSID : "\(status.wifiSSID) · \(status.wifiIP)"
    }

    /// 插著電不一定在充電（例如最佳化電池充電），用電池狀態碼區分
    private var batteryText: String {
        guard status.batteryLevel >= 0 else { return "—" }
        var t = "\(status.batteryLevel)%"
        switch status.batteryStatus {
        case 2: t += "（充電中）"
        case 5: t += "（已充飽）"
        case 4: t += status.pluggedIn ? "（已插電，未充電）" : ""
        default: if status.pluggedIn { t += "（已插電，未充電）" }
        }
        return t
    }

    private var capacityText: String? {
        guard let max = status.batteryMaxMah else { return nil }
        guard let design = status.batteryDesignMah else { return "\(max) mAh" }
        return "\(max) mAh / 設計 \(design) mAh（\(Int((Double(max) / Double(design) * 100).rounded()))%）"
    }

    private func loadStatus() async {
        let c = device.client
        if let s = await DeviceStatus.fetch(c) { status = s; statusLoaded = true }
        // df -k：總量、已用、可用（KB）。顯示「剩餘可用空間」與占總容量的百分比
        if let df = try? await c.shell("df -k /data | tail -1") {
            let p = df.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 4, let total = Double(p[1]), let used = Double(p[2]), let avail = Double(p[3]), total > 0 {
                func g(_ kb: Double) -> String { String(format: "%.0fG", kb / 1_048_576) }
                storage = "已用 \(g(used)) / 共 \(g(total))，剩餘可用空間 \(g(avail))（\(Int((avail / total * 100).rounded()))%）"
                storageLoaded = true
            }
        }
    }

    private func pickAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await DropHandler.handle(panel.urls, device: device) { message = $0 } }
    }
}

/// 總覽最上面：喜好項目與已開啟的 App，各自獨立一排
struct PinnedAppsStrip: View {
    let device: Device
    @ObservedObject var catalog: AppCatalog
    @ObservedObject private var settings = AppSettings.shared

    private var parts: (favorites: [String], openOnly: [String]) { catalog.sections(pins: settings.pinned(for: device)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("喜好項目", parts.favorites)
            row("已開啟", parts.openOnly)
        }
        .task(id: device.id) {
            if catalog.apps.isEmpty { await catalog.reload() }
            // 定時更新，已開啟與「目前在用」的標記才會跟著手機變
            while !Task.isCancelled {
                await catalog.refreshTasks()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    @ViewBuilder private func row(_ title: String, _ packages: [String]) -> some View {
        if !packages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(packages, id: \.self) { icon($0) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func icon(_ pkg: String) -> some View {
        VStack(spacing: 5) {
            AppIconView(catalog: catalog, package: pkg, size: 52)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(catalog.label(for: pkg)).font(.caption).lineLimit(1).frame(width: 72)
            RunningMark(running: catalog.running.contains(pkg), current: pkg == catalog.foreground)
        }
        .contentShape(Rectangle())
        .onTapGesture { WindowManager.shared.launch(device, package: pkg) }
        // 選單順序與 App 列相同：強制停止、在獨立視窗開啟、（分隔線）喜好項目
        .contextMenu {
            Button("強制停止") { Task { await catalog.forceStop(pkg) } }
            Button("在獨立視窗開啟") { WindowManager.shared.openApp(device, package: pkg) }
            Divider()
            Button(settings.isPinned(pkg, on: device) ? "移除喜好項目" : "加入喜好項目") { settings.togglePin(pkg, on: device) }
        }
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.callout)
            }
            .frame(width: 110, height: 70)
        }
        .buttonStyle(.bordered)
    }
}

/// 從拖放的 NSItemProvider 取出檔案 URL
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
}
