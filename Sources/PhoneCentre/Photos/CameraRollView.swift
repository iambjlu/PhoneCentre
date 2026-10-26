import AVKit
import SwiftUI

/// 動態載入縮圖：看得到的格子才排隊，批次在手機端產生縮圖，並存到磁碟快取
@MainActor
final class ThumbnailLoader: ObservableObject {
    let device: Device
    @Published private(set) var images: [String: NSImage] = [:]
    private var queue: [RemoteFile] = []
    private var inFlight: Set<String> = []
    private var running = false
    private var wanted: Set<String> = []

    init(device: Device) { self.device = device }

    private func cacheURL(_ f: RemoteFile) -> URL {
        CacheManager.shared.dir(device, "thumbs")
            .appendingPathComponent(stableHash("v2|\(f.path)|\(f.size)|\(f.modified.timeIntervalSince1970)") + ".jpg")
    }

    func appear(_ f: RemoteFile) {
        wanted.insert(f.path)
        guard images[f.path] == nil, !inFlight.contains(f.path) else { return }
        let url = cacheURL(f)
        if let img = NSImage(contentsOf: url) {
            images[f.path] = img
            return
        }
        queue.append(f)
        inFlight.insert(f.path)
        pump()
    }

    /// 捲出畫面的格子不再需要
    func disappear(_ f: RemoteFile) {
        wanted.remove(f.path)
        queue.removeAll { $0.path == f.path && !wanted.contains($0.path) }
        if images[f.path] == nil { inFlight.remove(f.path) }
    }

    private func pump() {
        guard !running else { return }
        running = true
        Task {
            // 稍等讓同一次捲動的格子一起批次處理
            try? await Task.sleep(nanoseconds: 80_000_000)
            while !queue.isEmpty {
                let batch = Array(queue.prefix(24))
                queue.removeFirst(batch.count)
                let out = (try? await HelperTool.shared.run(device, ["thumbs", "256"] + batch.map(\.path), timeout: 90)) ?? ""
                for line in out.split(separator: "\n") {
                    let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard p.count == 2, let data = Data(base64Encoded: p[1]), let img = NSImage(data: data),
                          let f = batch.first(where: { $0.path == p[0] }) else { continue }
                    try? data.write(to: cacheURL(f))
                    images[f.path] = img
                }
                for f in batch where images[f.path] == nil { inFlight.remove(f.path) }
            }
            running = false
            CacheManager.shared.recalc()
        }
    }
}

/// 相機膠卷的篩選：全部／只看照片／只看影片
enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "全部", photos = "照片", videos = "影片"
    var id: String { rawValue }
    func matches(_ f: RemoteFile) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !f.isVideo
        case .videos: return f.isVideo
        }
    }
}

/// Apple「照片」風格的相機膠卷
struct CameraRollView: View {
    /// 「所有照片」：DCIM 底下所有資料夾（含子資料夾）的照片與影片
    static let allPhotos = "@all"

    let device: Device
    private var fs: RemoteFS { RemoteFS(device: device) }

    @StateObject private var thumbs: ThumbnailLoader
    @State private var albums: [String] = []
    @State private var album = CameraRollView.allPhotos
    @State private var allItems: [RemoteFile] = []
    @State private var filter: MediaFilter = .all
    @State private var selection = Set<String>()
    /// ⇧ 範圍選取的起點（上一次點選的項目）
    @State private var anchor: String?
    @State private var loading = false
    @State private var zoom: Double = 140
    @State private var viewing: RemoteFile?
    @State private var status = ""
    @State private var dropTargeted = false

    init(device: Device) {
        self.device = device
        _thumbs = StateObject(wrappedValue: ThumbnailLoader(device: device))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("相簿", selection: $album) {
                    ForEach(albums, id: \.self) { a in Text(albumTitle(a)).tag(a) }
                }
                .fixedSize()
                Picker("", selection: $filter) {
                    ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("\(items.count) 個項目").foregroundStyle(.secondary).font(.callout)
                Spacer()
                if !selection.isEmpty {
                    Text("已選取 \(selection.count) 個").font(.callout).foregroundStyle(.secondary)
                    Button("匯出…") { export() }.keyboardShortcut("e", modifiers: .command)
                    Button("刪除", role: .destructive) { delete() }
                }
                // ⌘A 全選（目前篩選後看得到的項目）
                Button("") { selection = Set(items.map(\.id)) }.keyboardShortcut("a", modifiers: .command).opacity(0).frame(width: 0).accessibilityHidden(true)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 80...280).frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(10)
            Divider()
            grid
            if !status.isEmpty {
                Divider()
                Text(status).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .task { await loadAlbums() }
        .task(id: album) { await load() }
        .onChange(of: filter) { _, _ in selection = selection.filter { id in items.contains { $0.id == id } } }
        .sheet(item: $viewing) { f in MediaViewer(device: device, items: items.filter { !$0.isDir }, current: f) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: zoom, maximum: zoom * 1.4), spacing: 2)], spacing: 2) {
                ForEach(items) { f in
                    cell(f)
                }
            }
            .padding(2)
        }
        .overlay {
            if loading { ProgressView() }
            else if items.isEmpty { Text(filter == .all ? "這個相簿沒有照片或影片" : "這個相簿沒有\(filter.rawValue)").foregroundStyle(.tertiary) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in importFiles(urls) }
            return true
        }
        .border(dropTargeted ? Color.accentColor : .clear, width: 2)
    }

    private func cell(_ f: RemoteFile) -> some View {
        let selected = selection.contains(f.id)
        return Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = thumbs.images[f.path] {
                    Image(nsImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if f.isVideo {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                        .shadow(radius: 2).padding(5)
                }
            }
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(4)
                        }
                }
            }
            .contentShape(Rectangle())
            .onAppear { thumbs.appear(f) }
            .onDisappear { thumbs.disappear(f) }
            .onTapGesture(count: 2) { viewing = f }
            .onTapGesture { click(f) }
            .onDrag { remoteFileItemProvider(f, device: device) }
            .contextMenu {
                Button("打開") { viewing = f }
                Button("匯出…") { if !selected { selection = [f.id] }; export() }
                Button("刪除", role: .destructive) { if !selected { selection = [f.id] }; delete() }
            }
    }

    /// 跟 Finder／照片一樣：⌘ 點選加入或取消、⇧ 點選選取從上一次點的到這一個之間的範圍、一般點選只選這一個
    private func click(_ f: RemoteFile) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let a = anchor, let i = items.firstIndex(where: { $0.id == a }),
           let j = items.firstIndex(where: { $0.id == f.id }) {
            let range = items[min(i, j)...max(i, j)].map(\.id)
            if mods.contains(.command) { selection.formUnion(range) } else { selection = Set(range) }
            return
        }
        if mods.contains(.command) || mods.contains(.shift) {
            if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
        } else {
            selection = [f.id]
        }
        anchor = f.id
    }

    /// 目前篩選後顯示的項目
    private var items: [RemoteFile] { allItems.filter(filter.matches) }

    private func albumTitle(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        switch path {
        case Self.allPhotos: return "所有照片"
        case "/sdcard/DCIM/Camera": return "相機"
        case "/sdcard/DCIM/Screenshots", "/sdcard/Pictures/Screenshots": return "截圖"
        default: return name
        }
    }

    private func loadAlbums() async {
        var list = [Self.allPhotos, "/sdcard/DCIM/Camera"]
        let dcim = (try? await fs.list("/sdcard/DCIM", showHidden: false)) ?? []
        list += dcim.filter { $0.isDir && $0.path != "/sdcard/DCIM/Camera" }.map(\.path)
        let pics = (try? await fs.list("/sdcard/Pictures", showHidden: false)) ?? []
        list += pics.filter(\.isDir).map(\.path)
        albums = list
    }

    private func load() async {
        loading = true
        selection = []
        anchor = nil
        let list = album == Self.allPhotos
            ? ((try? await fs.listRecursive("/sdcard/DCIM")) ?? [])
            : ((try? await fs.list(album, showHidden: false)) ?? [])
        allItems = list.filter(\.isMedia).sorted { $0.modified > $1.modified }
        loading = false
    }

    private func export() {
        let sel = items.filter { selection.contains($0.id) }
        guard !sel.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "匯出到這裡"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            var used = Set<String>()
            for (i, f) in sel.enumerated() {
                status = "匯出中 (\(i + 1)/\(sel.count))：\(f.name)"
                // 「所有照片」可能有不同資料夾的同名檔案：名稱重複就加上編號，不互相覆蓋
                try? await device.client.pull(f.path, to: uniqueURL(dir, f.name, used: &used))
            }
            status = "已匯出 \(sel.count) 個項目到 \(dir.lastPathComponent)"
        }
    }

    private func uniqueURL(_ dir: URL, _ name: String, used: inout Set<String>) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while used.contains(candidate) || FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        used.insert(candidate)
        return dir.appendingPathComponent(candidate)
    }

    private func delete() {
        let sel = items.filter { selection.contains($0.id) }
        guard !sel.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "要從手機刪除 \(sel.count) 個項目嗎？"
        alert.informativeText = "會直接從手機刪除，無法復原。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            try? await fs.delete(sel.map(\.path))
            await load()
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            for (i, u) in urls.enumerated() {
                status = "匯入中 (\(i + 1)/\(urls.count))：\(u.lastPathComponent)"
                // 「所有照片」不是實際的資料夾，匯入到相機資料夾
                let target = album == Self.allPhotos ? "/sdcard/DCIM/Camera" : album
                try? await device.client.push(u, to: target + "/" + u.lastPathComponent)
            }
            status = "已匯入 \(urls.count) 個項目"
            await load()
        }
    }
}

/// 單張檢視：照片顯示原圖、影片用播放器；左右鍵切換
struct MediaViewer: View {
    let device: Device
    let items: [RemoteFile]
    @State var current: RemoteFile
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                Text(current.name).font(.headline)
                Text(current.modified.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary)
                Spacer()
                if let url { Button("用預設 App 打開") { NSWorkspace.shared.open(url) } }
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            ZStack {
                Color.black
                if let player {
                    AppKitPlayerView(player: player)
                } else if let url, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else if let error {
                    Text(error).foregroundStyle(.white)
                } else {
                    ProgressView("下載中…").colorScheme(.dark)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task(id: current.id) { await load() }
        .onDisappear { player?.pause() }
    }

    private func step(_ d: Int) {
        guard let i = items.firstIndex(of: current) else { return }
        let n = i + d
        if items.indices.contains(n) { current = items[n] }
    }

    private func load() async {
        player?.pause()
        player = nil
        url = nil
        error = nil
        do {
            let u = try await RemoteFS(device: device).download(toCache: current)
            url = u
            if current.isVideo {
                let p = AVPlayer(url: u)
                player = p
                p.play()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 影片播放：直接用 AppKit 的 AVPlayerView。SwiftUI 的 VideoPlayer（_AVKit_SwiftUI）在這個系統上
/// 初始化類別中繼資料時會直接崩潰（點開相機膠卷的影片就當機）。
struct AppKitPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
