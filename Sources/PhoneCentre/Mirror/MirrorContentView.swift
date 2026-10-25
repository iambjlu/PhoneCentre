import AppKit
import SwiftUI

struct MirrorViewRepresentable: NSViewRepresentable {
    let view: MirrorView
    func makeNSView(context: Context) -> MirrorView { view }
    func updateNSView(_ nsView: MirrorView, context: Context) {}
}

enum MirrorLayout {
    /// 右側欄（狀態指示、App 列、導覽列）寬度；視窗上方沒有工具列
    static let railWidth: CGFloat = 76
    static let toolbarHeight: CGFloat = 0
    static let minContentHeight: CGFloat = 560
}

/// 鏡像視窗內容：手機畫面 ＋ 右側欄（狀態指示 + App 列 + 導覽列）
struct MirrorContentView: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var catalog: AppCatalog
    @State private var showVideoSettings = false
    @State private var showPasswordSheet = false
    @State private var showLocation = false

    init(model: MirrorModel) {
        self.model = model
        self.catalog = model.catalog
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                MirrorViewRepresentable(view: model.view)
                overlays
                // 截圖：先全白再淡出
                Color.white.opacity(model.flashOpacity).allowsHitTesting(false)
            }
            SideColumn(model: model, catalog: catalog, showVideoSettings: $showVideoSettings, showLocation: $showLocation)
                .frame(width: MirrorLayout.railWidth)
        }
        .sheet(isPresented: $showPasswordSheet) {
            LockPasswordSheet(device: model.device)
        }
        .sheet(isPresented: $showLocation) {
            LocationSimulatorSheet(device: model.device)
        }
    }

    // MARK: 疊加訊息（一律毛玻璃底）

    @ViewBuilder
    private var overlays: some View {
        VStack {
            if model.showUnlockBanner && !model.isVirtualDisplay {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                    Text("手機已鎖定")
                    unlockButton
                    Button { model.dismissUnlock() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(10)
                .glassCard(cornerRadius: 12)
                .padding(.top, 10)
            }
            Spacer()
            if !model.markedText.isEmpty {
                Text(model.markedText)
                    .font(.title3)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassCard(cornerRadius: 16)
                    .padding(.bottom, 100)
            }
        }
        .allowsHitTesting(model.showUnlockBanner)
        // 手機鎖定時，虛擬顯示器上的 App 會黑屏：明確提示
        if model.locked && model.isVirtualDisplay && model.statusText == nil {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("手機已鎖定，解鎖後才會顯示 App 畫面").font(.headline).multilineTextAlignment(.center)
                unlockButton
            }
            .padding(24)
            .glassCard(cornerRadius: 18)
        }
        if model.appClosed, model.statusText == nil, let pkg = model.appPackage {
            // 最後一幀霧化當背景
            if let snap = model.closedSnapshot {
                Image(nsImage: snap).resizable().scaledToFill()
                    .blur(radius: 8)
                    .overlay(Rectangle().fill(Color.black.opacity(0.25)))
                    .clipped()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                AppIconView(catalog: catalog, package: pkg, size: 56).opacity(0.9)
                Text("\(model.appLabel ?? catalog.label(for: pkg)) 已關閉")
                    .font(.headline)
                Button("打開") { model.reopenApp() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(24)
            .glassCard(cornerRadius: 18)
        }
        if let s = model.statusText {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(s).font(.callout).multilineTextAlignment(.center)
            }
            .padding(20)
            .glassCard(cornerRadius: 16)
        }
        // 提示訊息顯示在畫面正中間
        if let t = model.toast {
            Text(t)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassCard(cornerRadius: 14)
                .padding(24)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var unlockButton: some View {
        // 子程序（Dock 獨立視窗）不碰鑰匙圈，解鎖交給主程式處理，所以一律顯示 Touch ID 按鈕
        if ChildMode.isChild || LockScreenHelper.hasPassword(model.device) {
            Button { model.unlock() } label: { Label("用 Touch ID 解鎖", systemImage: "touchid") }
                .buttonStyle(.borderedProminent)
        } else {
            Button("儲存解鎖密碼…") { showPasswordSheet = true }
        }
    }
}

/// App 列：已開啟（左邊有點）＋ 最近使用
struct AppRail: View {
    @ObservedObject var catalog: AppCatalog
    let onTap: (String) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var dragPkg: String?
    /// 往左或往右拖超過這個距離（拖出 App 列）放開才算
    static let tearOffDistance: CGFloat = 70

    /// 液態玻璃面板的高度跟著圖示數量：放得下就剛好包住，放不下才捲動
    var body: some View {
        if opened.isEmpty && unopenedPins.isEmpty {
            EmptyView()
        } else {
            ViewThatFits(in: .vertical) {
                iconList.liquidPanel()
                ScrollView(.vertical, showsIndicators: false) { iconList }.liquidPanel()
            }
        }
    }

    /// 第一個是目前在手機畫面最上層的 App；接著像 Mac Dock：使用者釘選的 App 一直在，執行中但沒釘選的接在分隔線後面
    private var current: String? { catalog.foreground }
    private var allPins: [String] { settings.pinned(for: catalog.device) }
    /// 已開啟的排前面：目前的 App → 已開啟的喜好項目 → 其他已開啟的；還沒開的喜好項目全部放最後（分隔線之後），才不會和已開啟的混在一起
    private var opened: [String] {
        let running = catalog.running
        return (current.map { [$0] } ?? [])
            + allPins.filter { running.contains($0) && $0 != current }
            + running.filter { !allPins.contains($0) && $0 != current }
    }
    private var unopenedPins: [String] { allPins.filter { !catalog.running.contains($0) && $0 != current } }

    private var iconList: some View {
        VStack(spacing: 10) {
            ForEach(opened, id: \.self) { pkg in
                railIcon(pkg, running: true)
            }
            if !opened.isEmpty && !unopenedPins.isEmpty {
                GlassDivider(opacity: 0.55).padding(.horizontal, 10)
            }
            ForEach(unopenedPins, id: \.self) { pkg in
                railIcon(pkg, running: false)
            }
        }
        .padding(.vertical, 10)
    }

    private func railIcon(_ pkg: String, running: Bool) -> some View {
        let dragging = dragPkg == pkg
        return ZStack {
            AppIconView(catalog: catalog, package: pkg, size: 38)
                .opacity(dragging ? 0.4 : 1)
            RunningMark(running: running, current: pkg == catalog.foreground, color: .white.opacity(0.8), vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap(pkg) }
        // 把圖示拖出 App 列放開 → 在獨立視窗開啟
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                dragPkg = pkg
                DragGhost.shared.show(icon: catalog.icon(for: pkg), at: NSEvent.mouseLocation,
                                      armed: abs(v.translation.width) > Self.tearOffDistance)
            }
            .onEnded { v in
                dragPkg = nil
                DragGhost.shared.hide()
                if abs(v.translation.width) > Self.tearOffDistance {
                    // 視窗左上角放在放開的位置
                    let m = NSEvent.mouseLocation
                    WindowManager.shared.openApp(catalog.device, package: pkg, at: NSPoint(x: m.x - 30, y: m.y + 20))
                }
            })
        .help(catalog.label(for: pkg))
        .contextMenu {
            Button("強制停止") { Task { await catalog.forceStop(pkg) } }
            Button("在獨立視窗開啟") { WindowManager.shared.openApp(catalog.device, package: pkg) }
            Divider()
            Button(settings.isPinned(pkg, on: catalog.device) ? "移除喜好項目" : "加入喜好項目") {
                settings.togglePin(pkg, on: catalog.device)
            }
        }
    }
}

/// 執行中標記：一般是小圓點；目前在手機主螢幕最上層的那個 App 拉長成圓角短線
struct RunningMark: View {
    let running: Bool
    let current: Bool
    var color: Color = .primary.opacity(0.6)
    var vertical = false

    var body: some View {
        if !running {
            Color.clear.frame(width: 4, height: 4)
        } else if current {
            Capsule().fill(color).frame(width: vertical ? 3 : 12, height: vertical ? 12 : 3)
        } else {
            Circle().fill(color).frame(width: 4, height: 4)
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

    private static let presets: [(name: String, options: VideoOptions)] = [
        ("省流量", VideoOptions(maxFps: 30, bitRateMbps: 2, maxSize: 1024)),
        ("一般", VideoOptions(maxFps: 60, bitRateMbps: 8, maxSize: 1920)),
        ("高畫質", VideoOptions(maxFps: 60, bitRateMbps: 20, maxSize: 0)),
    ]

    /// 目前設定對應的預設（-1 = 自訂）
    private var presetIndex: Int {
        Self.presets.firstIndex { $0.options.maxFps == options.maxFps && $0.options.bitRateMbps == options.bitRateMbps
            && $0.options.maxSize == options.maxSize } ?? -1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("畫質").font(.headline)

            Picker("", selection: Binding(get: { presetIndex }, set: { if $0 >= 0 { options = Self.presets[$0].options } })) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { Text($1.name).tag($0) }
                if presetIndex < 0 { Text("自訂").tag(-1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 12) {
                row("影格率") {
                    Picker("", selection: $options.maxFps) {
                        ForEach([15, 24, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("解析度上限") {
                    Picker("", selection: $options.maxSize) {
                        Text("不限制").tag(0)
                        ForEach([2560, 1920, 1600, 1280, 1024, 800, 640], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                VStack(spacing: 6) {
                    row("位元率") {
                        Text(String(format: "%.1f Mbps", options.bitRateMbps)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $options.bitRateMbps, in: 0.5...40).controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("套用") { apply(options) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }
}

/// 設定手機解鎖密碼（PIN／密碼或圖形，存在 Mac 鑰匙圈）
struct LockPasswordSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var pw = ""
    @State private var usePattern = false
    @State private var pattern: [Int] = []

    private var canSave: Bool { usePattern ? pattern.count >= 4 : !pw.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("「\(device.displayName)」的解鎖密碼").font(.headline)
            Text("密碼會存在這台 Mac 的鑰匙圈。偵測到手機在鎖定畫面時，可用 Touch ID 驗證後自動填入。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $usePattern) {
                Text("PIN／密碼").tag(false)
                Text("圖形").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if usePattern {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        PatternPad(sequence: $pattern)
                        HStack {
                            Text(pattern.isEmpty ? "在上面畫出圖形（至少 4 個點）" : pattern.map(String.init).joined(separator: " → "))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("清除") { pattern = [] }.controlSize(.small)
                        }
                    }
                    Spacer()
                }
            } else {
                SecureField("PIN 或密碼", text: $pw)
            }
            HStack {
                if LockScreenHelper.hasPassword(device) {
                    Button("刪除已儲存的密碼", role: .destructive) {
                        LockScreenHelper.setPassword(nil, for: device); dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") {
                    let value = usePattern ? LockScreenHelper.patternPrefix + pattern.map(String.init).joined() : pw
                    LockScreenHelper.setPassword(value, for: device); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
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
