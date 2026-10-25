import AppKit
import SwiftUI

struct MirrorViewRepresentable: NSViewRepresentable {
    let view: MirrorView
    func makeNSView(context: Context) -> MirrorView { view }
    func updateNSView(_ nsView: MirrorView, context: Context) {}
}

enum MirrorLayout {
    static let toolbarHeight: CGFloat = 38
    static let railWidth: CGFloat = 64
}

/// 鏡像視窗內容：左側 App 列 + 上方工具列 + 手機畫面
struct MirrorContentView: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var catalog: AppCatalog
    @State private var showVideoSettings = false
    @State private var showPasswordSheet = false
    @State private var showLauncher = false

    init(model: MirrorModel) {
        self.model = model
        self.catalog = model.catalog
    }

    var body: some View {
        HStack(spacing: 0) {
            if !model.isAppWindow {
                AppRail(catalog: catalog) { pkg in model.launch(pkg) }
                    .frame(width: MirrorLayout.railWidth)
                Divider()
            }
            VStack(spacing: 0) {
                toolbar
                    .frame(height: MirrorLayout.toolbarHeight)
                Divider()
                ZStack {
                    MirrorViewRepresentable(view: model.view)
                    overlays
                }
            }
        }
        .background(Color.black)
        .sheet(isPresented: $showPasswordSheet) {
            LockPasswordSheet(device: model.device)
        }
    }

    // MARK: 工具列

    private var toolbar: some View {
        HStack(spacing: 2) {
            ToolButton("power", "電源") { model.key(KeyMap.power) }
            ToolButton("speaker.wave.3", "音量 +") { model.key(KeyMap.volumeUp) }
            ToolButton("speaker.wave.1", "音量 −") { model.key(KeyMap.volumeDown) }
            Divider().frame(height: 18)
            ToolButton("rotate.right", "旋轉") { model.session?.send(.rotateDevice) }
            ToolButton("chevron.backward", "返回（右鍵／Esc）") { model.key(KeyMap.back) }
            ToolButton("circle", "主畫面（中鍵）") { model.key(KeyMap.home) }
            ToolButton("square.on.square", "最近使用") { model.key(KeyMap.appSwitch) }
            ToolButton("bell", "通知欄") { model.session?.send(.expandNotifications) }
            Divider().frame(height: 18)
            ToolButton("camera", "截圖存到桌面") { model.screenshot() }
            if model.desktopMode {
                ToolButton("square.grid.3x3", "在這個桌面開啟 App") { showLauncher.toggle() }
                    .popover(isPresented: $showLauncher) {
                        MiniLauncher(catalog: catalog) { pkg in showLauncher = false; model.launch(pkg) }
                    }
            }
            if !model.isVirtualDisplay {
                ToolButton(model.screenOff ? "iphone.slash" : "iphone", model.screenOff ? "點亮手機螢幕" : "讓手機黑屏（繼續鏡像）") {
                    model.toggleScreenOff()
                }
                if AppSettings.shared.audioEnabled {
                    ToolButton(model.muted ? "speaker.slash" : "speaker", model.muted ? "取消靜音" : "Mac 端靜音") { model.toggleMute() }
                }
            }
            Spacer(minLength: 4)
            Menu {
                Picker("鍵盤", selection: $model.keyboardMode) {
                    ForEach(KeyboardMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: model.keyboardMode == .physical ? "keyboard" : "character.cursor.ibeam")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("鍵盤輸入模式：\(model.keyboardMode.title)")
            ToolButton("slider.horizontal.3", "畫質設定") { showVideoSettings.toggle() }
                .popover(isPresented: $showVideoSettings) {
                    VideoSettingsPopover(options: model.videoOptions) { model.applyVideoOptions($0) }
                }
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }

    // MARK: 疊加訊息

    @ViewBuilder
    private var overlays: some View {
        VStack {
            if model.showUnlockBanner {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                    Text("手機已鎖定")
                    if LockScreenHelper.hasPassword(model.device) {
                        Button { model.unlock() } label: { Label("用 Touch ID 填入密碼", systemImage: "touchid") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("儲存解鎖密碼…") { showPasswordSheet = true }
                    }
                    Button { model.dismissUnlock() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 10)
            }
            Spacer()
            if !model.markedText.isEmpty {
                Text(model.markedText)
                    .font(.title3)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 100)
            }
            if let t = model.toast {
                Text(t)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(model.showUnlockBanner)
        if model.desktopMode, model.statusText == nil, model.desktopEmpty {
            VStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle").font(.largeTitle)
                Text("從左側 App 列或工具列的 \(Image(systemName: "square.grid.3x3")) 開啟 App")
                Text("這支手機的桌面程式不支援第二螢幕，所以這裡沒有桌面背景。").font(.caption)
            }
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
        if let s = model.statusText {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(s).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white)
            }
            .padding()
        }
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// 左側 App 列：已開啟（左邊有點）＋ 最近使用
struct AppRail: View {
    @ObservedObject var catalog: AppCatalog
    let onTap: (String) -> Void
    @State private var dragPkg: String?
    /// 往右拖超過這個距離（拖出 App 列）放開才算
    static let tearOffDistance: CGFloat = 70

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(catalog.running, id: \.self) { pkg in
                    railIcon(pkg, running: true)
                }
                if !catalog.running.isEmpty && !catalog.recent.isEmpty {
                    Divider().padding(.horizontal, 12)
                }
                ForEach(catalog.recent, id: \.self) { pkg in
                    railIcon(pkg, running: false)
                }
            }
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func railIcon(_ pkg: String, running: Bool) -> some View {
        let dragging = dragPkg == pkg
        return HStack(spacing: 3) {
            Circle().fill(running ? Color.primary.opacity(0.7) : .clear).frame(width: 4, height: 4)
            AppIconView(catalog: catalog, package: pkg, size: 40)
                .opacity(dragging ? 0.4 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap(pkg) }
        // 把圖示拖出 App 列放開 → 在獨立視窗開啟
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                dragPkg = pkg
                DragGhost.shared.show(icon: catalog.icon(for: pkg), at: NSEvent.mouseLocation,
                                      armed: v.translation.width > Self.tearOffDistance)
            }
            .onEnded { v in
                dragPkg = nil
                DragGhost.shared.hide()
                if v.translation.width > Self.tearOffDistance {
                    // 視窗左上角放在放開的位置
                    let m = NSEvent.mouseLocation
                    WindowManager.shared.openApp(catalog.device, package: pkg, at: NSPoint(x: m.x - 30, y: m.y + 20))
                }
            })
        .help(catalog.label(for: pkg))
        .contextMenu {
            Button("在獨立視窗開啟") { WindowManager.shared.openApp(catalog.device, package: pkg) }
            Button("強制停止") { Task { await catalog.forceStop(pkg) } }
        }
    }
}

struct AppIconView: View {
    @ObservedObject var catalog: AppCatalog
    let package: String
    let size: CGFloat

    var body: some View {
        Group {
            if let img = catalog.icon(for: package) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.secondary.opacity(0.25))
                    .overlay(Text(String(catalog.label(for: package).prefix(1))).font(.system(size: size * 0.4, weight: .semibold)))
            }
        }
        .frame(width: size, height: size)
    }
}

struct VideoSettingsPopover: View {
    @State var options: VideoOptions
    let apply: (VideoOptions) -> Void

    var body: some View {
        Form {
            Picker("FPS", selection: $options.maxFps) {
                ForEach([15, 24, 30, 45, 60, 90, 120], id: \.self) { Text("\($0)").tag($0) }
            }
            HStack {
                Text("Bitrate")
                Slider(value: $options.bitRateMbps, in: 0.5...40, step: 0.5)
                Text(String(format: "%.1f Mbps", options.bitRateMbps)).monospacedDigit().frame(width: 72, alignment: .trailing)
            }
            Picker("最大解析度", selection: $options.maxSize) {
                Text("不限制").tag(0)
                ForEach([2560, 1920, 1600, 1280, 1024, 800, 640], id: \.self) { Text("\($0)").tag($0) }
            }
            HStack {
                Button("網路差") { options = VideoOptions(maxFps: 30, bitRateMbps: 2, maxSize: 1024) }
                Button("一般") { options = VideoOptions(maxFps: 60, bitRateMbps: 8, maxSize: 1920) }
                Button("高畫質") { options = VideoOptions(maxFps: 60, bitRateMbps: 20, maxSize: 0) }
                Spacer()
                Button("套用") { apply(options) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// 設定手機解鎖密碼（存在 Mac 鑰匙圈）
struct LockPasswordSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var pw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("「\(device.displayName)」的解鎖密碼").font(.headline)
            Text("密碼會存在這台 Mac 的鑰匙圈。偵測到手機在鎖定畫面時，可用 Touch ID 驗證後自動填入。")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("PIN 或密碼", text: $pw)
            HStack {
                if LockScreenHelper.hasPassword(device) {
                    Button("刪除已儲存的密碼", role: .destructive) {
                        LockScreenHelper.setPassword(nil, for: device); dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") {
                    LockScreenHelper.setPassword(pw, for: device); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pw.isEmpty)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// 拖曳 App 圖示時跟著游標的半透明圖示（可以拖到視窗外面）
@MainActor
final class DragGhost {
    static let shared = DragGhost()
    private var panel: NSPanel?
    private let imageView = NSImageView()
    private let badge = NSImageView()

    func show(icon: NSImage?, at point: NSPoint, armed: Bool) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.hasShadow = true
            imageView.frame = NSRect(x: 4, y: 4, width: 56, height: 56)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            badge.frame = NSRect(x: 40, y: 0, width: 24, height: 24)
            badge.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)
            badge.contentTintColor = .systemGreen
            p.contentView?.addSubview(imageView)
            p.contentView?.addSubview(badge)
            panel = p
        }
        imageView.image = icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        badge.isHidden = !armed
        panel?.alphaValue = armed ? 0.95 : 0.6
        panel?.setFrameOrigin(NSPoint(x: point.x - 32, y: point.y - 32))
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

/// 桌面模式的小型啟動台
struct MiniLauncher: View {
    @ObservedObject var catalog: AppCatalog
    let onPick: (String) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("搜尋 App", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 8), count: 5), spacing: 12) {
                    ForEach(catalog.apps.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }) { a in
                        VStack(spacing: 4) {
                            AppIconView(catalog: catalog, package: a.package, size: 44)
                            Text(a.label).font(.caption2).lineLimit(1)
                        }
                        .frame(width: 72)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(a.package) }
                    }
                }
            }
            .frame(height: 360)
            .overlay { if catalog.apps.isEmpty { ProgressView() } }
        }
        .padding(12)
        .frame(width: 420)
        .task { if catalog.apps.isEmpty { await catalog.reload() } }
    }
}
