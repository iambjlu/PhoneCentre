import SwiftUI

enum DataKind: String, CaseIterable, Identifiable {
    case notifications = "通知", sms = "簡訊", calls = "通話記錄"
    var id: String { rawValue }
}

private enum NotificationScope: String, CaseIterable, Identifiable {
    case active = "現在", all = "所有"
    var id: String { rawValue }
}

/// 通知／簡訊／通話記錄各自一個分頁（通知再分「還在」與「已清除」）
struct PhoneDataView: View {
    let device: Device
    let kind: DataKind
    @ObservedObject private var catalog: AppCatalog
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = PhoneDataStore.shared
    @State private var scope: NotificationScope = .active
    @State private var query = ""
    @State private var showOngoing = false
    @State private var confirmDelete = false

    init(device: Device, kind: DataKind) {
        self.device = device
        self.kind = kind
        _catalog = ObservedObject(wrappedValue: DeviceManager.shared.catalog(for: device))
    }

    var body: some View {
        if !settings.phoneDataEnabled {
            VStack(spacing: 14) {
                Image(systemName: "bell.badge").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("保存\(kind.rawValue)").font(.title2.bold())
                Text("PhoneCentre 會定時透過 adb 讀取手機上的簡訊、通知與通話記錄並保存在這台 Mac，不需要在手機安裝任何程式。\n保存天數可在「設定 → 儲存」分別調整。這些是個人隱私資料，只存在這台 Mac 的本機。")
                    .multilineTextAlignment(.center).frame(maxWidth: 460).foregroundStyle(.secondary)
                Button("開啟") { settings.data.phoneDataEnabled = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(28)
            .glassCard(cornerRadius: 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let b = store.bundle(for: device)
            VStack(spacing: 0) {
                header(b)
                content(b)
            }
            .task(id: device.id) { await store.sync(device) }
            .confirmationDialog("刪除這台手機已保存的簡訊、通知與通話記錄？", isPresented: $confirmDelete) {
                Button("刪除", role: .destructive) { store.deleteAll(for: device) }
            }
        }
    }

    // MARK: 標頭

    /// 跟啟動台一樣的單列控制列：左邊篩選，右邊搜尋與動作
    private func header(_ b: PhoneDataBundle) -> some View {
        HStack(spacing: 12) {
            if kind == .notifications {
                Picker("", selection: $scope) {
                    ForEach(NotificationScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("顯示常駐通知", isOn: $showOngoing).toggleStyle(.checkbox)
            }
            Spacer()
            PhoneDataRetentionPicker(title: "保存期限", days: retentionDays)
                .fixedSize()
                .onChange(of: retentionDays.wrappedValue) { _, _ in store.prune() }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .frame(width: 240)
            Button { Task { await store.sync(device) } } label: {
                // 更新中就在按鈕原位轉圈，寬度固定，旁邊的搜尋欄不會被擠動
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(syncing ? 0 : 1)
                    if syncing { ProgressView().controlSize(.small) }
                }
                .frame(width: 18, height: 18)
            }
            .disabled(syncing)
                .help("立即更新" + (b.lastSync.map { "（上次更新 " + $0.formatted(date: .omitted, time: .standard) + "）" } ?? ""))
            Menu {
                Button("停止收集", role: .destructive) { settings.data.phoneDataEnabled = false }
                Button("刪除已保存的資料…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12)
    }

    private var syncing: Bool { store.syncing.contains(CacheManager.key(for: device)) }

    /// 這個分頁對應的保存天數設定（和「設定 → 儲存」同一份）
    private var retentionDays: Binding<Int> {
        switch kind {
        case .notifications: return $settings.data.notificationRetentionDays
        case .sms: return $settings.data.smsRetentionDays
        case .calls: return $settings.data.callRetentionDays
        }
    }

    // MARK: 內容

    @ViewBuilder
    private func content(_ b: PhoneDataBundle) -> some View {
        switch kind {
        case .notifications:
            let list = b.notifications
                .filter { scope == .all || $0.isActive }
                .filter { showOngoing || !$0.ongoing }
                .filter { matches($0.title, $0.text, $0.package) }
                .sorted { ($0.clearedAt ?? $0.firstSeen) > ($1.clearedAt ?? $1.firstSeen) }
            if list.isEmpty { empty(scope == .active ? "目前手機上沒有通知" : "沒有通知") }
            else {
                listPanel(list) { n in
                    HStack(alignment: .top, spacing: 10) {
                        AppIconView(catalog: catalog, package: n.package, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(catalog.label(for: n.package)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary.opacity(0.8)).lineLimit(1)
                                Spacer()
                                Text(n.firstSeen.formatted(date: .abbreviated, time: .shortened)
                                     + (n.clearedAt.map { "　清除於 " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                                    .font(.subheadline).foregroundStyle(.primary.opacity(0.7))
                            }
                            if !n.title.isEmpty { Text(n.title).font(.headline) }
                            if !n.text.isEmpty { Text(n.text).textSelection(.enabled) }
                        }
                    }
                }
                .task(id: Set(list.map(\.package))) {
                    if catalog.apps.isEmpty { await catalog.reload() }
                    catalog.loadIcons(Array(Set(list.map(\.package))))
                }
            }
        case .sms:
            PhoneSMSView(messages: b.sms, query: query)
        case .calls:
            let list = b.calls.filter { matches($0.name, $0.number) }.sorted { $0.date > $1.date }
            if list.isEmpty { empty("沒有通話記錄") }
            else {
                listPanel(list) { c in
                    HStack {
                        Image(systemName: c.symbol).foregroundStyle(c.isMissed ? .red : .secondary).frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(c.name.isEmpty ? (c.number.isEmpty ? "未知號碼" : c.number) : c.name)
                                .font(.headline).foregroundStyle(c.isMissed ? .red : .primary)
                            Text(c.name.isEmpty ? c.typeTitle : "\(c.number) · \(c.typeTitle)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(c.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            if c.duration > 0 { Text(durationText(c.duration)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 跟簡訊對話列表同一種風格：一塊液態玻璃面板，列與列之間有分隔線
    private func listPanel<T: Identifiable, R: View>(_ items: [T], @ViewBuilder row: @escaping (T) -> R) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.id != items.last?.id { Divider().padding(.horizontal, 14) }
                }
            }
            .padding(.vertical, 6)
        }
        .liquidPanel(cornerRadius: 22)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ fields: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private func durationText(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600) 時 \(s % 3600 / 60) 分" : s >= 60 ? "\(s / 60) 分 \(s % 60) 秒" : "\(s) 秒"
    }
}

/// 設定頁用：各類資料的保存天數
struct PhoneDataRetentionPicker: View {
    let title: String
    @Binding var days: Int
    static let options = [1, 3, 7, 14, 30, 60, 90, 180, 365, 0]

    var body: some View {
        Picker(title, selection: $days) {
            ForEach(Self.options + (Self.options.contains(days) ? [] : [days]), id: \.self) {
                Text($0 == 0 ? "永久" : "\($0) 天").tag($0)
            }
        }
    }
}
