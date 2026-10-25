import AppKit
import SwiftUI

enum DeviceTab: String, CaseIterable, Identifiable {
    case overview = "總覽", launchpad = "啟動台", files = "檔案", photos = "相機膠卷"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "iphone"
        case .launchpad: return "square.grid.3x3"
        case .files: return "folder"
        case .photos: return "photo.on.rectangle"
        }
    }
}

struct MainView: View {
    @ObservedObject private var dm = DeviceManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var remote = RemoteManager.shared
    @State private var selection: String?
    @State private var tab: DeviceTab = .overview
    @State private var showAdd = false
    @State private var editingHost: RemoteHost?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .sheet(isPresented: $showAdd) { AddDeviceSheet() }
        .sheet(item: $editingHost) { RemoteHostEditSheet(host: $0) }
        .onAppear { if selection == nil { selection = dm.onlineDevices.first?.id } }
        .onChange(of: dm.devices) { _, list in
            if selection == nil || !list.contains(where: { $0.id == selection }) {
                selection = list.first(where: \.isOnline)?.id ?? selection
            }
        }
    }

    // MARK: 側邊欄

    private var sidebar: some View {
        List(selection: $selection) {
            Section("裝置") {
                ForEach(dm.devices.filter { !$0.isRemote }) { d in DeviceRow(device: d).tag(d.id) }
                ForEach(offlineSaved) { ep in
                    HStack {
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(ep.name ?? ep.address)
                            Text(dm.reconnecting.contains(ep.address) ? "重新連線中…" : "離線 · \(ep.address)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("立即重連") { Task { _ = await dm.connect(ep.address) } }
                        Button("忘記這台裝置", role: .destructive) { dm.forget(ep) }
                    }
                }
                if dm.devices.isEmpty && offlineSaved.isEmpty {
                    Text("插上已開啟 USB 偵錯的手機，或按 + 加入無線裝置").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(settings.remoteHosts) { h in
                let ds = dm.devices.filter { $0.endpoint.remoteID == h.id }
                Section {
                    ForEach(ds) { d in DeviceRow(device: d).tag(d.id) }
                    if ds.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(remote.status[h.id] ?? "未連線").font(.caption).foregroundStyle(.secondary)
                            Button("重新連線") { remote.reconnect(h) }.controlSize(.small)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(ds.isEmpty ? Color.orange : .green).frame(width: 7, height: 7)
                        Text("\(h.name)（遠端）")
                        Spacer()
                        Menu {
                            Button("重新連線") { remote.reconnect(h) }
                            Button("編輯…") { editingHost = h }
                            Divider()
                            Button("移除", role: .destructive) {
                                settings.remoteHosts.removeAll { $0.id == h.id }
                                settings.setSecret(h.secretKey, nil)
                                remote.apply()
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                .contextMenu {
                    Button("重新連線") { remote.reconnect(h) }
                    Button("編輯…") { editingHost = h }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .toolbar {
            ToolbarItem {
                Button { showAdd = true } label: { Label("加入裝置", systemImage: "plus") }
                    .help("加入無線裝置或遠端 PhoneCentre")
            }
        }
    }

    private var offlineSaved: [SavedEndpoint] {
        let online = Set(dm.devices.filter(\.isOnline).map(\.serial))
        let onlineSN = Set(dm.devices.compactMap { $0.isOnline ? $0.info?.serialNo : nil })
        return settings.savedEndpoints.filter { !online.contains($0.address) && !($0.serialNo.map(onlineSN.contains) ?? false) }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(serverColor).frame(width: 7, height: 7)
                Text(serverText).font(.caption)
                Spacer()
                if settings.keepAlive {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                        .help("自動維持連線已開啟")
                }
            }
            if !dm.lastEvent.isEmpty {
                Text(dm.lastEvent).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .glassShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
    }

    private var serverColor: Color {
        switch dm.serverStatus {
        case .running: return .green
        case .down: return .orange
        case .missingAdb: return .red
        case .unknown: return .gray
        }
    }

    private var serverText: String {
        switch dm.serverStatus {
        case .running: return "adb server 執行中"
        case .down: return settings.keepAlive ? "adb server 停止，正在重新啟動…" : "adb server 未執行"
        case .missingAdb: return "找不到 adb"
        case .unknown: return "檢查中…"
        }
    }

    // MARK: 內容

    @ViewBuilder
    private var detail: some View {
        if dm.serverStatus == .missingAdb {
            AdbSetupView()
        } else if let id = selection, let d = dm.device(id: id) {
            if d.isOnline {
                VStack(spacing: 0) {
                    TabBar(selection: $tab)
                        .padding(10)
                    Divider()
                    switch tab {
                    case .overview: DeviceOverview(device: d)
                    case .launchpad: LaunchpadView(device: d, catalog: dm.catalog(for: d))
                    case .files: FileBrowserView(device: d).id(d.id)
                    case .photos: CameraRollView(device: d).id(d.id)
                    }
                }
                .navigationTitle(d.displayName)
                .navigationSubtitle(d.subtitle)
            } else {
                ContentUnavailableView(d.displayName, systemImage: "exclamationmark.triangle", description: Text(d.stateDescription))
            }
        } else {
            ContentUnavailableView("尚未選擇裝置", systemImage: "iphone.gen3",
                                   description: Text("用 USB 連接已開啟「USB 偵錯」的 Android 手機，或按右上角 + 加入無線裝置。"))
        }
    }
}

struct DeviceRow: View {
    let device: Device
    var body: some View {
        HStack {
            Image(systemName: device.symbolName).frame(width: 22)
                .foregroundStyle(device.isOnline ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(device.displayName)
                Text(device.isOnline ? (device.isWireless ? device.serial : device.subtitle) : device.stateDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(device.isOnline ? .green : .orange).frame(width: 7, height: 7)
        }
        .contextMenu {
            if device.isOnline {
                Button("鏡像畫面") { WindowManager.shared.openMirror(device) }
            }
            if device.isWireless && !device.isRemote {
                Button("中斷連線", role: .destructive) { Task { await DeviceManager.shared.disconnect(device) } }
            }
        }
    }
}

/// 找不到 adb 時：一鍵從 Google 官方下載安裝
struct AdbSetupView: View {
    @State private var working = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("需要 Android 偵錯工具（adb）").font(.title2.bold())
            Text("PhoneCentre 透過 adb 和手機溝通。按下按鈕後會從 Google 官方網站下載 Android SDK Platform-Tools，安裝到 PhoneCentre 自己的資料夾，不會影響系統其他設定。")
                .multilineTextAlignment(.center).frame(maxWidth: 460).foregroundStyle(.secondary)
            Text("下載即表示同意 [Android SDK 授權條款](https://developer.android.com/studio/terms)。")
                .font(.caption)
            Button {
                working = true
                Task {
                    do {
                        _ = try await AdbLocator.install { msg in Task { @MainActor in message = msg } }
                        await DeviceManager.shared.refresh()
                    } catch {
                        message = error.localizedDescription
                    }
                    working = false
                }
            } label: {
                Label("下載並安裝 adb", systemImage: "arrow.down.circle")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working)
            if working { ProgressView() }
            Text(message).font(.callout).foregroundStyle(.secondary)
            Text("已經有 adb？可在「設定 → 連線」指定路徑。").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// 視窗底部是毛玻璃（桌面透出來）；macOS 15 以上用 containerBackground
    @ViewBuilder func windowGlassBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(for: .window) { WindowBlur() }
        } else {
            self
        }
    }
}

/// 視窗後面桌面的模糊（真正的毛玻璃，不是半透明）
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// 玻璃分頁列：整條是一塊液態玻璃，選到的項目用淡色膠囊標示（不再疊原生分段控制的外框）
struct TabBar: View {
    @Binding var selection: DeviceTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DeviceTab.allCases) { t in
                Button { selection = t } label: {
                    Text(t.rawValue)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(Color.primary.opacity(selection == t ? 0.2 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(maxWidth: 380)
        .glassShape(Capsule())
    }
}
