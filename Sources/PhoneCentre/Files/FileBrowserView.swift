import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Finder 風格的手機檔案管理
struct FileBrowserView: View {
    let device: Device
    private var fs: RemoteFS { RemoteFS(device: device) }

    @State private var path = "/sdcard"
    @State private var back: [String] = []
    @State private var forward: [String] = []
    @State private var files: [RemoteFile] = []
    @State private var selection = Set<RemoteFile.ID>()
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    @State private var loading = false
    @State private var error: String?
    @State private var showHidden = false
    @State private var status = ""
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var dropTargeted = false

    private let places: [(String, String, String)] = [
        ("內部儲存空間", "internaldrive", "/sdcard"),
        ("下載項目", "arrow.down.circle", "/sdcard/Download"),
        ("相機", "camera", "/sdcard/DCIM"),
        ("圖片", "photo", "/sdcard/Pictures"),
        ("文件", "doc", "/sdcard/Documents"),
        ("音樂", "music.note", "/sdcard/Music"),
        ("影片", "film", "/sdcard/Movies"),
        ("暫存 (/data/local/tmp)", "hammer", "/data/local/tmp"),
        ("根目錄", "externaldrive", "/"),
    ]

    var body: some View {
        HSplitView {
            List {
                Section("位置") {
                    ForEach(places, id: \.2) { p in
                        Label(p.0, systemImage: p.1)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { go(p.2) }
                            .listRowBackground(path == p.2 ? Color.accentColor.opacity(0.2) : nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            VStack(spacing: 0) {
                toolbar
                Divider()
                table
                Divider()
                HStack {
                    Text(status.isEmpty ? "\(files.count) 個項目" : status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .task(id: path) { await load() }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $newName)
            Button("重新命名") { if let f = renaming { doRename(f) } }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 工具列

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(back.isEmpty)
            Button { goForward() } label: { Image(systemName: "chevron.right") }.disabled(forward.isEmpty)
            Button { goUp() } label: { Image(systemName: "arrow.up") }.disabled(path == "/").help("上一層")
            pathBar
            Spacer()
            Toggle(isOn: $showHidden) { Image(systemName: "eye") }
                .toggleStyle(.button).help("顯示隱藏檔")
                .onChange(of: showHidden) { _, _ in Task { await load() } }
            Button { newFolder() } label: { Image(systemName: "folder.badge.plus") }.help("新增資料夾")
            Button { upload() } label: { Image(systemName: "square.and.arrow.up") }.help("上傳檔案到這裡")
            Button { downloadSelected() } label: { Image(systemName: "square.and.arrow.down") }
                .disabled(selection.isEmpty).help("下載到 Mac")
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var pathBar: some View {
        let comps = path == "/" ? [] : path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("/") { go("/") }.buttonStyle(.borderless)
                ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(c) { go("/" + comps[0...i].joined(separator: "/")) }.buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: 表格

    private var table: some View {
        Table(of: RemoteFile.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名稱", value: \.name, comparator: .localizedStandard) { f in
                HStack(spacing: 6) {
                    Image(nsImage: f.icon).resizable().frame(width: 18, height: 18)
                    Text(f.name).lineLimit(1)
                }
            }
            .width(min: 200, ideal: 340)
            TableColumn("修改日期", value: \.modified) { f in
                Text(f.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
            TableColumn("大小", value: \.size) { f in
                Text(f.isDir ? "—" : f.size.fileSizeString).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("種類", value: \.kind) { f in Text(f.kind).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 120)
        } rows: {
            ForEach(sorted) { f in
                TableRow(f).itemProvider { remoteFileItemProvider(f, device: device) }
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, let f = files.first(where: { $0.id == id }) { open(f) }
        }
        .overlay {
            if loading { ProgressView() }
            else if let error { Text(error).foregroundStyle(.secondary).padding() }
            else if files.isEmpty { Text("資料夾是空的").foregroundStyle(.tertiary) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in push(urls) }
            return true
        }
        .border(dropTargeted ? Color.accentColor : .clear, width: 2)
        .onDeleteCommand { deleteSelected() }
    }

    private var sorted: [RemoteFile] {
        // 資料夾一律在前面，像 Finder 的「資料夾排前面」
        let s = files.sorted(using: sortOrder)
        return s.filter(\.isDir) + s.filter { !$0.isDir }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<RemoteFile.ID>) -> some View {
        let sel = files.filter { ids.contains($0.id) }
        if sel.count == 1, let f = sel.first {
            Button("打開") { open(f) }
            if !f.isDir { Button("快速查看") { quickLook(f) } }
            Button("重新命名…") { newName = f.name; renaming = f }
            Button("拷貝路徑") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(f.path, forType: .string)
            }
        }
        if !sel.isEmpty {
            Button("下載到 Mac…") { selection = ids; downloadSelected() }
            Divider()
            Button("刪除", role: .destructive) { selection = ids; deleteSelected() }
        } else {
            Button("新增資料夾") { newFolder() }
            Button("上傳檔案到這裡…") { upload() }
        }
    }

    // MARK: 導覽

    private func go(_ p: String) {
        guard p != path else { return }
        back.append(path)
        forward.removeAll()
        path = p
    }

    private func goBack() { if let p = back.popLast() { forward.append(path); path = p } }
    private func goForward() { if let p = forward.popLast() { back.append(path); path = p } }
    private func goUp() { go((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) }

    private func load() async {
        loading = true
        error = nil
        selection = []
        do {
            files = try await fs.list(path, showHidden: showHidden)
        } catch {
            files = []
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func open(_ f: RemoteFile) {
        if f.isDir { go(f.path); return }
        Task {
            status = "正在下載 \(f.name)…"
            do {
                let url = try await fs.download(toCache: f)
                NSWorkspace.shared.open(url)
                status = ""
            } catch { status = error.localizedDescription }
        }
    }

    private func quickLook(_ f: RemoteFile) {
        Task {
            status = "正在下載 \(f.name)…"
            if let url = try? await fs.download(toCache: f) {
                QuickLookPresenter.shared.show([url])
            }
            status = ""
        }
    }

    // MARK: 檔案操作

    private func newFolder() {
        Task {
            var name = "未命名資料夾"
            var i = 2
            while files.contains(where: { $0.name == name }) { name = "未命名資料夾 \(i)"; i += 1 }
            do { try await fs.mkdir(join(name)) } catch { status = error.localizedDescription }
            await load()
        }
    }

    private func doRename(_ f: RemoteFile) {
        let target = join(newName)
        Task {
            do { try await fs.rename(f.path, to: target) } catch { status = error.localizedDescription }
            await load()
        }
    }

    private func deleteSelected() {
        let sel = files.filter { selection.contains($0.id) }
        guard !sel.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = sel.count == 1 ? "要刪除「\(sel[0].name)」嗎？" : "要刪除 \(sel.count) 個項目嗎？"
        alert.informativeText = "手機上的檔案會直接刪除，無法復原。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await fs.delete(sel.map(\.path)) } catch { status = error.localizedDescription }
            await load()
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        push(panel.urls)
    }

    private func push(_ urls: [URL]) {
        Task {
            for (i, u) in urls.enumerated() {
                status = "上傳中 (\(i + 1)/\(urls.count))：\(u.lastPathComponent)"
                do { try await device.client.push(u, to: join(u.lastPathComponent)) } catch { status = error.localizedDescription }
            }
            status = ""
            await load()
        }
    }

    private func downloadSelected() {
        let sel = files.filter { selection.contains($0.id) }
        guard !sel.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "下載到這裡"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            for (i, f) in sel.enumerated() {
                status = "下載中 (\(i + 1)/\(sel.count))：\(f.name)"
                do { try await device.client.pull(f.path, to: dir.appendingPathComponent(f.name)) } catch { status = error.localizedDescription }
            }
            status = "已下載到 \(dir.path)"
        }
    }

    private func join(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }
}

/// 簡易 Quick Look 面板
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }
}
