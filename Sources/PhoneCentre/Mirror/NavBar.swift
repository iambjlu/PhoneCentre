import AppKit
import SwiftUI

// MARK: 毛玻璃

extension View {
    /// 疊在畫面上的東西統一用毛玻璃當底：新系統用液態玻璃，舊系統用材質
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// 右側欄：浮在視窗邊緣的圓角液態玻璃面板
    @ViewBuilder func glassColumn() -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(macOS 26.0, *) {
            self.clipShape(shape).glassEffect(.regular, in: shape)
        } else {
            self.clipShape(shape).background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: 狀態指示

/// 類似新版 iPhone 的狀態指示：外環＝電池（左右兩段，上方留給數字），中間＝Wi-Fi 或行動網路世代，
/// 下方的點＝主要 SIM 卡訊號格（跟電池環分開）
struct StatusIndicator: View {
    let status: DeviceStatus
    var size: CGFloat = 38

    private var level: Double { status.batteryLevel < 0 ? 0 : Double(status.batteryLevel) / 100 }
    private var ringColor: Color {
        if status.charging { return .green }
        if status.batteryLevel >= 0 && status.batteryLevel <= 20 { return .red }
        return .white
    }

    // 角度：SwiftUI 由 3 點鐘方向順時針量起（270° = 正上方，90° = 正下方）
    private let segments: [(Double, Double)] = [(145, 250), (290, 395)]

    var body: some View {
        ZStack {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = min(sz.width, sz.height) / 2 - 2
                func arc(_ from: Double, _ to: Double) -> Path {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                    return p
                }
                let style = StrokeStyle(lineWidth: 3.2, lineCap: .round)
                for seg in segments { ctx.stroke(arc(seg.0, seg.1), with: .color(.white.opacity(0.22)), style: style) }
                // 電量依序填滿兩段（左段先、右段後）
                let total = segments.reduce(0) { $0 + ($1.1 - $1.0) }
                var remain = total * level
                for seg in segments where remain > 0 {
                    let len = min(remain, seg.1 - seg.0)
                    ctx.stroke(arc(seg.0, seg.0 + len), with: .color(ringColor), style: style)
                    remain -= len
                }
            }
            if status.batteryLevel >= 0 {
                Text("\(status.batteryLevel)")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(status.charging ? Color.green : Color.white)
                    .offset(y: -size / 2 - 1)
            }
            center.offset(y: -size * 0.02)
            if status.hasSim {
                // 訊號格：在 Wi-Fi 下方，排成微彎的一排（兩端略高）
                let r = size * 0.47
                ForEach(0..<4, id: \.self) { i in
                    let phi = [-0.62, -0.2, 0.2, 0.62][i]
                    Circle().fill(Color.white.opacity(i < status.signalBars ? 1 : 0.28))
                        .frame(width: 3.6, height: 3.6)
                        .offset(x: r * CGFloat(sin(phi)), y: r * CGFloat(cos(phi)) - 1)
                }
            }
        }
        .frame(width: size, height: size)
        .padding(.top, 22)
        .padding(.bottom, 4)
        .help(status.summary)
    }

    @ViewBuilder private var center: some View {
        if status.wifi {
            Image(systemName: "wifi", variableValue: Double(status.wifiLevel) / 4)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        } else if let t = status.cellularTech {
            Text(t).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white)
        } else {
            Image(systemName: "wifi.slash").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
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
            .opacity(enabled ? 1 : 0.35)
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
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 48, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.16 : 0)))
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

/// 把 SF Symbol 旋轉後做成選單用的圖示（選單裡的 View 修飾無效，所以要先畫成圖）
func rotatedSymbol(_ name: String, degrees: Double) -> Image {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return Image(systemName: name) }
    let side = max(base.size.width, base.size.height) + 2
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let t = NSAffineTransform()
        t.translateX(by: rect.midX, yBy: rect.midY)
        t.rotate(byDegrees: CGFloat(degrees))
        t.translateX(by: -base.size.width / 2, yBy: -base.size.height / 2)
        t.concat()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    img.isTemplate = true
    return Image(nsImage: img)
}

// MARK: 三星風格的返回／主畫面／多工

/// One UI 的三個系統按鍵：返回「<」、主畫面「圓角方形」、多工「|||」
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

/// 強制停止：六角形加叉叉
struct StopAppIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "hexagon")
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
        }
    }
}

// MARK: 右側欄（狀態指示 ＋ App 列 ＋ 導覽列）

struct SideColumn: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var catalog: AppCatalog
    @Binding var showVideoSettings: Bool
    @Binding var showLocation: Bool
    @State private var showLauncher = false

    var body: some View {
        VStack(spacing: 0) {
            StatusIndicator(status: model.status).padding(.bottom, 6)
            if model.isAppWindow {
                Spacer(minLength: 0)
            } else {
                AppRail(catalog: catalog) { pkg in model.launch(pkg) }
            }
            Divider().padding(.horizontal, 10).opacity(0.4)
            navBar.padding(.vertical, 6)
        }
        .environment(\.colorScheme, .dark)
        .glassColumn()
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private var navBar: some View {
        VStack(spacing: 1) {
            NavButton(help: "畫質設定") { showVideoSettings.toggle() } icon: { sfIcon("dial.medium") }
                .popover(isPresented: $showVideoSettings) {
                    VideoSettingsPopover(options: model.videoOptions) { model.applyVideoOptions($0) }
                }
            NavMenu(help: "輸入方式：\(model.keyboardMode.title)") {
                sfIcon(model.keyboardMode == .physical ? "keyboard" : "keyboard.fill")
            } items: {
                ForEach(KeyboardMode.allCases) { m in
                    Button { model.keyboardMode = m } label: {
                        Label(m.title + (model.keyboardMode == m ? "  ✓" : ""),
                              systemImage: m == .physical ? "keyboard" : "keyboard.fill")
                    }
                }
            }
            if model.desktopMode {
                NavButton(help: "在這個桌面開啟 App") { showLauncher.toggle() } icon: { sfIcon("square.grid.2x2") }
                    .popover(isPresented: $showLauncher) {
                        MiniLauncher(catalog: catalog) { pkg in showLauncher = false; model.launch(pkg) }
                    }
            }
            NavButton(help: "模擬定位") { showLocation = true } icon: { sfIcon("location") }
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
                    ForEach([(0, "直向", 0.0), (1, "橫向（向左）", 90.0), (2, "直向（倒立）", 180.0), (3, "橫向（向右）", 270.0)], id: \.0) { r in
                        Button { model.setRotation(r.0) } label: {
                            Label {
                                Text(r.1 + (!model.status.autoRotate && model.status.userRotation == r.0 ? "  ✓" : ""))
                            } icon: { rotatedSymbol("iphone", degrees: r.2) }
                        }
                    }
                    Divider()
                    Toggle("自動旋轉", isOn: Binding(get: { model.status.autoRotate }, set: { model.setAutoRotate($0) }))
                }
            }
            if !model.isVirtualDisplay {
                NavButton(help: model.screenOff ? "點亮手機螢幕" : "讓手機黑屏（繼續鏡像）") { model.toggleScreenOff() }
                    icon: { sfIcon(model.screenOff ? "iphone.slash" : "iphone") }
                NavButton(help: "電源") { model.key(KeyMap.power) } icon: { sfIcon("power") }
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 2).opacity(0.4)
            recentsButton
            homeButton
            NavButton(help: "返回（右鍵／Esc）") { model.navBack() } icon: { SamsungNavIcon.Back() }
        }
    }

    /// 獨立視窗：隱藏視窗；桌面模式：該桌面的 Home；主螢幕：手機 Home
    @ViewBuilder private var homeButton: some View {
        if model.isAppWindow {
            NavButton(help: "隱藏視窗（App 留在虛擬顯示器上繼續執行；再從 App 列開啟或點 Dock 圖示叫回來）") { model.hideWindow() } icon: { sfIcon("xmark.square") }
        } else {
            NavButton(help: model.isVirtualDisplay ? "桌面 Home" : "主畫面（中鍵）") { model.navHome() } icon: { SamsungNavIcon.Home() }
        }
    }

    /// 獨立視窗：強制停止並關閉視窗；桌面模式：該桌面的最近使用；主螢幕：手機的最近使用
    @ViewBuilder private var recentsButton: some View {
        if model.isAppWindow {
            NavButton(help: "強制停止 App 並關閉視窗") { model.forceStopAndClose() } icon: { StopAppIcon() }
        } else {
            NavButton(help: "最近使用") { model.navRecents() } icon: { SamsungNavIcon.Recents() }
        }
    }
}
