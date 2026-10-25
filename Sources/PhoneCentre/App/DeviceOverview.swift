import SwiftUI
import UniformTypeIdentifiers

struct DeviceOverview: View {
    let device: Device
    @State private var battery = ""
    @State private var storage = ""
    @State private var showPassword = false
    @State private var message = ""
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "iphone.gen3").font(.system(size: 56)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName).font(.title.bold())
                        Text(device.subtitle).foregroundStyle(.secondary)
                        Text(device.isRemote ? "透過遠端 PhoneCentre" : (device.isWireless ? "無線 · \(device.serial)" : "USB · \(device.serial)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

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
                        row("電池", battery.isEmpty ? "—" : battery)
                        row("儲存空間", storage.isEmpty ? "—" : storage)
                        row("序號", device.info?.serialNo ?? device.serial)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.4))
                    .frame(height: 90)
                    .overlay(Text(message.isEmpty ? "把檔案拖到這裡：APK 會安裝、照片影片存到相機膠卷、其他存到 Download" : message)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding())
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        loadURLs(providers) { urls in
                            Task { await DropHandler.handle(urls, device: device) { message = $0 } }
                        }
                        return true
                    }

                Text("Samsung DeX 需要實體的外接螢幕（或 Samsung 自己的無線 DeX）才會啟動，用 adb 建立的虛擬顯示器無法觸發。「桌面模式」改用 Android 內建的桌面模式：建立一個橫向、帶系統列的虛擬顯示器，可在裡面同時開多個 App。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task(id: device.id) { await loadStatus() }
        .sheet(isPresented: $showPassword) { LockPasswordSheet(device: device) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(v).textSelection(.enabled)
        }
    }

    private func loadStatus() async {
        let c = device.client
        if let b = try? await c.shell("dumpsys battery") {
            let level = b.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("level:") }
                .map { $0.replacingOccurrences(of: "level:", with: "").trimmingCharacters(in: .whitespaces) } ?? "?"
            let charging = b.contains("AC powered: true") || b.contains("USB powered: true") || b.contains("Wireless powered: true")
            battery = "\(level)%" + (charging ? "（充電中）" : "")
        }
        if let df = try? await c.shell("df -h /data | tail -1") {
            let p = df.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 4 { storage = "已用 \(p[2]) / 共 \(p[1])，剩餘 \(p[3])" }
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
