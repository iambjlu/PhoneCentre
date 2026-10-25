import SwiftUI

/// 啟動台的分組索引：英文字母 A–Z → 注音 ㄅ–ㄦ → 其他（#）
enum AppIndex {
    static let bopomofo = Array("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ").map(String.init)
    static let order: [String] = (65...90).map { String(UnicodeScalar($0)!) } + bopomofo + ["#"]
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func key(for label: String) -> String {
        guard let f = label.first else { return "#" }
        let first = String(f)
        if let k = cache[first] { return k }
        var k = "#"
        if f.isASCII {
            if f.isLetter { k = first.uppercased() }
        } else if let py = first.applyingTransform(.mandarinToLatin, reverse: false),
                  let bp = py.applyingTransform(StringTransform("Latin-Bopomofo"), reverse: false),
                  let c = bp.first, bopomofo.contains(String(c)) {
            k = String(c)
        } else if let c = first.applyingTransform(.toLatin, reverse: false)?.first, c.isASCII, c.isLetter {
            k = String(c).uppercased()   // 日文、韓文、西里爾字母等轉成拉丁字母後歸類
        }
        cache[first] = k
        return k
    }

    static func rank(_ k: String) -> Int { order.firstIndex(of: k) ?? order.count }
}

/// 類似 Mac 新版啟動台：上方開啟方式選單＋搜尋，下面 App 圖示格
struct LaunchpadView: View {
    let device: Device
    @ObservedObject var catalog: AppCatalog
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var confirmUninstall: AppEntry?

    private var pins: [String] { settings.pinned(for: device) }

    private func entries(_ pkgs: [String]) -> [AppEntry] {
        pkgs.compactMap { p in catalog.apps.first { $0.package == p } }
    }

    private var filteredApps: [AppEntry] {
        catalog.apps.filter { a in
            query.isEmpty || a.label.localizedCaseInsensitiveContains(query) || a.package.localizedCaseInsensitiveContains(query)
        }
    }

    /// 依索引分組（A–Z、ㄅ–ㄦ、#），組內照名稱排序
    private func grouped(_ apps: [AppEntry]) -> [(key: String, apps: [AppEntry])] {
        Dictionary(grouping: apps) { AppIndex.key(for: $0.label) }
            .map { (key: $0.key, apps: $0.value.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }) }
            .sorted { AppIndex.rank($0.key) < AppIndex.rank($1.key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("開啟方式", selection: $settings.data.launchTarget) {
                    ForEach(AppLaunchTarget.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
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
                content
            }
        }
        .task(id: device.id) {
            if catalog.apps.isEmpty { await catalog.reload() }
            // 定時更新，已開啟與「目前在用」的標記才會跟著手機變
            while !Task.isCancelled {
                await catalog.refreshTasks()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .alert("解除安裝「\(confirmUninstall?.label ?? "")」？", isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })) {
            Button("解除安裝", role: .destructive) {
                if let a = confirmUninstall { Task { _ = await catalog.uninstall(a.package) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 沒有搜尋時：喜好項目、已開啟、依索引分組的所有 App，右邊有 A–Z／ㄅ–ㄦ 索引列可以快速跳轉
    private var content: some View {
        ScrollViewReader { proxy in
            // 「喜好項目」（已開啟的在前）與「已開啟」（已開啟但沒加入喜好項目的）
            let parts = catalog.sections(pins: pins)
            let pinnedApps = entries(parts.favorites)
            let openApps = entries(parts.openOnly)
            let taken = Set(pinnedApps.map(\.package) + openApps.map(\.package))
            let groups = grouped(filteredApps.filter { query.isEmpty ? !taken.contains($0.package) : true })
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if query.isEmpty {
                        section("喜好項目", pinnedApps)
                        section("已開啟", openApps)
                        if !groups.isEmpty, !(pinnedApps.isEmpty && openApps.isEmpty) {
                            Text("所有 App").font(.headline).foregroundStyle(.secondary).padding(.bottom, -12)
                        }
                        ForEach(groups, id: \.key) { g in
                            section(g.key, g.apps, small: true).id("idx-\(g.key)")
                        }
                    } else {
                        section(nil, filteredApps.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending })
                    }
                }
                .padding(.vertical, 20)
                .padding(.leading, 20)
                .padding(.trailing, 36)
            }
            .overlay(alignment: .trailing) {
                if query.isEmpty, groups.count > 1 { indexRail(groups.map(\.key), proxy) }
            }
        }
    }

    private func indexRail(_ keys: [String], _ proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let step = max(min(geo.size.height / CGFloat(keys.count), 16), 9)
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { k in
                    Text(k).font(.system(size: min(step - 1, 11), weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: step)
                }
            }
            .background(.quaternary.opacity(0.5), in: Capsule())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let i = min(max(Int(v.location.y / step), 0), keys.count - 1)
                proxy.scrollTo("idx-\(keys[i])", anchor: .top)
            })
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 22)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func section(_ title: String?, _ apps: [AppEntry], small: Bool = false) -> some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    Text(title).font(small ? .subheadline.weight(.semibold) : .headline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(apps) { cell($0) }
                }
            }
        }
    }

    private func cell(_ app: AppEntry) -> some View {
        VStack(spacing: 6) {
            AppIconView(catalog: catalog, package: app.package, size: 64)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(app.label).font(.caption).lineLimit(1).truncationMode(.tail)
            RunningMark(running: catalog.running.contains(app.package), current: app.package == catalog.foreground)
        }
        .frame(width: 96)
        .contentShape(Rectangle())
        .onTapGesture { WindowManager.shared.launch(device, package: app.package) }
        .help(app.package)
        .contextMenu { menu(app) }
    }

    /// 選單順序與 App 列相同：強制停止、在獨立視窗開啟在最上面，動到喜好項目的放最下面
    @ViewBuilder
    private func menu(_ app: AppEntry) -> some View {
        Button("強制停止") { Task { await catalog.forceStop(app.package) } }
        Button("在獨立視窗開啟") { WindowManager.shared.openApp(device, package: app.package) }
        Button("在手機主螢幕開啟") {
            Task { await catalog.launch(app.package) }
            WindowManager.shared.openMirror(device)
        }
        Divider()
        Button("在手機上顯示 App 資訊") { Task { await catalog.openAppInfo(app.package) } }
        Button("拷貝套件名稱") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.package, forType: .string)
        }
        Button("解除安裝…", role: .destructive) { confirmUninstall = app }
        Divider()
        Button(settings.isPinned(app.package, on: device) ? "移除喜好項目" : "加入喜好項目") {
            settings.togglePin(app.package, on: device)
        }
    }
}
