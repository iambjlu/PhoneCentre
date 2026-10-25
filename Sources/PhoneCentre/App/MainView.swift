import AppKit
import SwiftUI

enum DeviceTab: String, CaseIterable, Identifiable {
    case overview = "總覽", launchpad = "啟動台", files = "檔案", notifications = "通知", sms = "簡訊", calls = "通話記錄", photos = "相機膠卷"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "iphone"
        case .launchpad: return "square.grid.3x3"
        case .files: return "folder"
        case .photos: return "photo.on.rectangle"
        case .notifications: return "bell.badge"
        case .sms: return "message"
        case .calls: return "phone"
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
    @State private var detailWidth: CGFloat = 800
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
                ForEach(dm.devices.filter { !$0.isRemote }) { d in deviceRow(d) }
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
                    ForEach(ds) { d in deviceRow(d) }
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

    private func deviceRow(_ d: Device) -> some View {
        let on: Bool = selection == d.id
        return DeviceRow(device: d, isSelected: on).tag(d.id)
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
                // 分頁：標準的分段選擇器放在工具列（用最新 SDK 連結後由系統畫成玻璃藥丸）。
                // 內容只建立目前選到的分頁（其他分頁不用先載入縮圖、檔案列表）
                Group {
                    switch tab {
                    case .overview: DeviceOverview(device: d)
                    case .launchpad: LaunchpadView(device: d, catalog: dm.catalog(for: d))
                    case .files: FileBrowserView(device: d).id(d.id)
                    case .photos: CameraRollView(device: d).id(d.id)
                    case .notifications: PhoneDataView(device: d, kind: .notifications).id(d.id)
                    case .sms: PhoneDataView(device: d, kind: .sms).id(d.id)
                    case .calls: PhoneDataView(device: d, kind: .calls).id(d.id)
                    }
                }                .softScrollEdge()
                .navigationTitle(d.displayName)
                .navigationSubtitle(d.subtitle)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
                .modifier(DeviceToolbar(device: d, tab: $tab, width: detailWidth))
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
    /// 選中的列底色是強調色，圖示與狀態燈要換色才不會和底色糊在一起。
    /// 由 MainView 直接告知是否選中（新版側邊欄的選取底色不一定會改變 backgroundProminence）
    var isSelected = false
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { isSelected || prominence == .increased }

    var body: some View {
        HStack {
            Image(systemName: device.symbolName).frame(width: 22)
                .foregroundStyle(selected ? Color.white : device.isOnline ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(device.displayName)
                Text(device.isOnline ? (device.isWireless ? device.serial : device.subtitle) : device.stateDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(device.isOnline ? .green : .orange).frame(width: 7, height: 7)
                .overlay { if selected { Circle().stroke(.white, lineWidth: 1.5).frame(width: 10, height: 10) } }
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
    /// 內容捲到工具列下面時用柔和的淡出（預設的硬邊會在工具列後面出現一塊長方形底板）
    @ViewBuilder func softScrollEdge() -> some View {
        if #available(macOS 26.0, *) { self.scrollEdgeEffectStyle(.soft, for: .top).scrollEdgeEffectHidden(true, for: .top) } else { self }
    }
}


/// 工具列：這一條跟內容區（側邊欄以外）同寬；裝置名稱靠左，分頁選擇器空間夠時在中間，
/// 被名稱擠到才往右移一點，名稱放不下才截斷。隱藏系統標題，名稱與副標題自己畫。
private struct DeviceToolbar: ViewModifier {
    let device: Device
    @Binding var tab: DeviceTab
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TitleTabsLayout {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.displayName).font(.headline).lineLimit(1)
                            Text(device.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.leading, 8)
                        Picker("", selection: $tab) {
                            ForEach(DeviceTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .frame(width: max(width - 24, 300))
                }
            }
    }
}

/// 第一個子視圖（名稱）靠左；第二個（分頁）盡量置中，會被名稱擠到才往右移，名稱放不下才截斷
private struct TitleTabsLayout: Layout {
    var gap: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let t = subviews[0].sizeThatFits(.unspecified), p = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? t.width + gap + p.width, height: max(t.height, p.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let title = subviews[0], tabs = subviews[1]
        let tw = title.sizeThatFits(.unspecified).width
        let pw = tabs.sizeThatFits(.unspecified).width
        var x = max(bounds.midX - pw / 2, bounds.minX + tw + gap)   // 置中，被名稱擠到才右移
        x = min(x, bounds.maxX - pw)
        title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: max(x - gap - bounds.minX, 0), height: bounds.height))
        tabs.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}
