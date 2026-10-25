import AppKit
import SwiftUI

// MARK: 狀態指示

/// 類似新版 iPhone 的狀態指示：外環＝電池，中間＝Wi-Fi 或行動網路世代，下方＝主要 SIM 卡訊號格
struct StatusIndicator: View {
    let status: DeviceStatus
    var size: CGFloat = 34

    private var level: Double { status.batteryLevel < 0 ? 0 : Double(status.batteryLevel) / 100 }
    private var ringColor: Color {
        if status.charging { return .green }
        if status.batteryLevel >= 0 && status.batteryLevel <= 20 { return .red }
        return Color.primary.opacity(0.55)
    }

    var body: some View {
        VStack(spacing: 1) {
            if status.batteryLevel >= 0 {
                HStack(spacing: 1) {
                    if status.charging { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)) }
                    Text("\(status.batteryLevel)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(status.charging ? Color.green : Color.primary.opacity(0.7))
            }
            ring
        }
        .help(status.summary)
    }

    private var ring: some View {
        ZStack {
            // 缺口在下方的 270° 圓環，從左下開始順時針
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * level)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            center.offset(y: -size * 0.04)
            if status.hasSim {
                // 訊號格沿著外環的圓弧排在缺口裡，跟電池環接成一個圓
                let r = size / 2 - 1.5
                ForEach(0..<4, id: \.self) { i in
                    let a = Angle.degrees(120 - Double(i) * 20).radians
                    Circle().fill(Color.primary.opacity(i < status.signalBars ? 0.8 : 0.22))
                        .frame(width: 3.2, height: 3.2)
                        .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var center: some View {
        if status.wifi {
            Image(systemName: "wifi").font(.system(size: size * 0.32, weight: .semibold))
        } else if let t = status.cellularTech {
            Text(t).font(.system(size: size * 0.28, weight: .bold, design: .rounded))
        } else {
            Image(systemName: "wifi.slash").font(.system(size: size * 0.28, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: 按鍵

/// 導覽列按鍵：SF Symbols 或自繪圖示，滑過有底色
struct NavButton<Icon: View>: View {
    let help: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hover = false

    var body: some View {
        Button(action: action) { NavButtonFace(hover: hover, content: icon) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hover = $0 }
            .help(help)
    }
}

struct NavButtonFace<Content: View>: View {
    let hover: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(width: 48, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hover ? 0.12 : 0)))
            .contentShape(Rectangle())
    }
}

/// 選單按鍵：外觀與 NavButton 相同，沒有下拉箭頭
struct NavMenu<Icon: View, Items: View>: View {
    let help: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let items: () -> Items
    @State private var hover = false

    var body: some View {
        Menu { items() } label: { NavButtonFace(hover: hover, content: icon) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hover = $0 }
            .help(help)
    }
}

func sfIcon(_ name: String) -> some View { Image(systemName: name) }

// MARK: 三星風格的返回／主畫面／多工

/// One UI 的三個系統按鍵：返回「<」、主畫面「○」、多工「|||」
enum SamsungNavIcon {
    struct Back: View {
        var body: some View {
            Canvas { ctx, size in
                var p = Path()
                let cx = size.width / 2, cy = size.height / 2
                p.move(to: CGPoint(x: cx + 3.5, y: cy - 7))
                p.addLine(to: CGPoint(x: cx - 3.5, y: cy))
                p.addLine(to: CGPoint(x: cx + 3.5, y: cy + 7))
                ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 20, height: 20)
            .scaleEffect(1.15)
        }
    }

    struct Home: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1.9)).frame(width: 14, height: 14)
                .frame(width: 20, height: 20)
                .scaleEffect(1.15)
        }
    }

    struct Recents: View {
        var body: some View {
            HStack(spacing: 4.2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().frame(width: 1.9, height: 14)
                }
            }
            .frame(width: 20, height: 20)
            .scaleEffect(1.15)
        }
    }
}

// MARK: 左側欄（狀態指示 ＋ App 列 ＋ 導覽列）

struct SideColumn: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var catalog: AppCatalog
    @Binding var showVideoSettings: Bool
    @State private var showLauncher = false

    var body: some View {
        VStack(spacing: 0) {
            StatusIndicator(status: model.status).padding(.vertical, 8)
            if model.isAppWindow {
                Spacer(minLength: 0)
            } else {
                AppRail(catalog: catalog) { pkg in model.launch(pkg) }
            }
            Divider().padding(.horizontal, 10)
            navBar.padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var navBar: some View {
        VStack(spacing: 1) {
            NavButton(help: "畫質設定") { showVideoSettings.toggle() } icon: { sfIcon("dial.medium") }
                .popover(isPresented: $showVideoSettings) {
                    VideoSettingsPopover(options: model.videoOptions) { model.applyVideoOptions($0) }
                }
            NavMenu(help: "輸入方式：\(model.keyboardMode.title)") {
                sfIcon(model.keyboardMode == .physical ? "keyboard" : "character.bubble")
            } items: {
                Picker("輸入方式", selection: $model.keyboardMode) {
                    ForEach(KeyboardMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            if model.desktopMode {
                NavButton(help: "在這個桌面開啟 App") { showLauncher.toggle() } icon: { sfIcon("square.grid.2x2") }
                    .popover(isPresented: $showLauncher) {
                        MiniLauncher(catalog: catalog) { pkg in showLauncher = false; model.launch(pkg) }
                    }
            }
            NavButton(help: "虛擬定位（尚未提供）") { model.showToast("虛擬定位尚未提供") } icon: { sfIcon("location") }
            NavMenu(help: "聲音") { sfIcon("speaker.wave.2") } items: {
                Button("音量 +") { model.key(KeyMap.volumeUp) }
                Button("音量 −") { model.key(KeyMap.volumeDown) }
                if !model.isVirtualDisplay && AppSettings.shared.audioEnabled {
                    Divider()
                    Button(model.muted ? "取消 Mac 端靜音" : "Mac 端靜音") { model.toggleMute() }
                }
            }
            NavButton(help: "截圖存到桌面") { model.screenshot() } icon: { sfIcon("camera") }
            NavMenu(help: "旋轉") { sfIcon("rotate.right") } items: {
                if model.isVirtualDisplay {
                    Button("旋轉視窗方向") { model.rotateVirtualDisplay() }
                } else {
                    Button("旋轉 90°") { model.session?.send(.rotateDevice) }
                    Divider()
                    Button("直向（鎖定）") { model.setRotation(.portrait) }
                    Button("橫向（鎖定）") { model.setRotation(.landscape) }
                    Button("自動旋轉") { model.setRotation(.auto) }
                }
            }
            if !model.isVirtualDisplay {
                NavButton(help: model.screenOff ? "點亮手機螢幕" : "讓手機黑屏（繼續鏡像）") { model.toggleScreenOff() }
                    icon: { sfIcon(model.screenOff ? "iphone.slash" : "iphone") }
                NavButton(help: "電源") { model.key(KeyMap.power) } icon: { sfIcon("power") }
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 2)
            recentsButton
            NavButton(help: model.isVirtualDisplay ? "回到 App 首頁" : "主畫面（中鍵）") { model.navHome() } icon: { SamsungNavIcon.Home() }
            NavButton(help: "返回（右鍵／Esc）") { model.navBack() } icon: { SamsungNavIcon.Back() }
        }
    }

    @ViewBuilder private var recentsButton: some View {
        if model.isVirtualDisplay {
            // 虛擬顯示器沒有自己的最近使用畫面：改成在這個視窗切換 App
            NavMenu(help: "在這個視窗切換 App") { SamsungNavIcon.Recents() } items: {
                ForEach(catalog.running + catalog.recent, id: \.self) { pkg in
                    Button(catalog.label(for: pkg)) { model.launch(pkg) }
                }
            }
            .onAppear { Task { await catalog.refreshTasks() } }
        } else {
            NavButton(help: "最近使用") { model.key(KeyMap.appSwitch) } icon: { SamsungNavIcon.Recents() }
        }
    }
}
