import SwiftUI

/// 類似 Mac 新版啟動台：上方開啟方式選單＋搜尋，下面 App 圖示格
struct LaunchpadView: View {
    let device: Device
    @ObservedObject var catalog: AppCatalog
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var filter = 0     // 0 全部、1 使用者、2 系統
    @State private var confirmUninstall: AppEntry?

    /// 釘選的排最前面，其次是已開啟的，最後是其他（各自維持原本順序）
    private var shown: [AppEntry] {
        let pins = settings.pinned(for: device)
        let running = catalog.running
        func rank(_ a: AppEntry) -> Int {
            if let i = pins.firstIndex(of: a.package) { return i }
            if let i = running.firstIndex(of: a.package) { return 1_000 + i }
            return 100_000
        }
        let filtered = filteredApps
        let indexed = Array(filtered.enumerated())
        return indexed.sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private var filteredApps: [AppEntry] {
        catalog.apps.filter { a in
            (filter == 0 || (filter == 1 && !a.isSystem) || (filter == 2 && a.isSystem))
                && (query.isEmpty || a.label.localizedCaseInsensitiveContains(query) || a.package.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("開啟方式", selection: $settings.data.launchTarget) {
                    ForEach(AppLaunchTarget.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("", selection: $filter) {
                    Text("全部").tag(0); Text("使用者").tag(1); Text("系統").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .frame(width: 240)
                Button { Task { await catalog.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新整理")
            }
            .padding(12)

            if catalog.loading && catalog.apps.isEmpty {
                Spacer(); ProgressView("讀取 App 清單…"); Spacer()
            } else if let e = catalog.error, catalog.apps.isEmpty {
                Spacer(); Text(e).foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 18)], spacing: 22) {
                        ForEach(shown) { app in
                            VStack(spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    AppIconView(catalog: catalog, package: app.package, size: 64)
                                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                                    if settings.isPinned(app.package, on: device) {
                                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.white)
                                            .padding(4).background(Circle().fill(Color.accentColor))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                            .offset(x: 6, y: -4)
                                    }
                                }
                                Text(app.label).font(.caption).lineLimit(1).truncationMode(.tail)
                                Circle().fill(catalog.running.contains(app.package) ? Color.primary.opacity(0.6) : .clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(width: 96)
                            .contentShape(Rectangle())
                            .onTapGesture { WindowManager.shared.launch(device, package: app.package) }
                            .help(app.package)
                            .contextMenu { menu(app) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task(id: device.id) {
            if catalog.apps.isEmpty { await catalog.reload() }
            await catalog.refreshTasks()
        }
        .alert("解除安裝「\(confirmUninstall?.label ?? "")」？", isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })) {
            Button("解除安裝", role: .destructive) {
                if let a = confirmUninstall { Task { _ = await catalog.uninstall(a.package) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func menu(_ app: AppEntry) -> some View {
        Button(settings.isPinned(app.package, on: device) ? "取消釘選" : "釘選到最上面") {
            settings.togglePin(app.package, on: device)
        }
        Divider()
        Button("在獨立視窗開啟") { WindowManager.shared.openApp(device, package: app.package) }
        Button("在手機主螢幕開啟") {
            Task { await catalog.launch(app.package) }
            WindowManager.shared.openMirror(device)
        }
        Divider()
        Button("在手機上顯示 App 資訊") { Task { await catalog.openAppInfo(app.package) } }
        Button("強制停止") { Task { await catalog.forceStop(app.package) } }
        Button("拷貝套件名稱") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.package, forType: .string)
        }
        Divider()
        Button("解除安裝…", role: .destructive) { confirmUninstall = app }
    }
}
