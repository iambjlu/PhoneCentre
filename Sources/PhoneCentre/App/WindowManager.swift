import AppKit
import Foundation

/// 開啟鏡像／App 視窗。依 Dock 設定決定在本程序開視窗，或啟動一個獨立的子程序（Dock 上獨立圖示）。
@MainActor
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var open: [String: MirrorWindowController] = [:]

    private func key(_ d: Device, _ pkg: String?, desktop: Bool = false) -> String {
        "\(d.id)#\(pkg ?? (desktop ? "@desktop" : "@main"))"
    }

    /// 主螢幕鏡像
    func openMirror(_ device: Device) {
        if AppSettings.shared.mirrorDockMode == .separate, !ChildMode.isChild {
            DockLauncher.launch(device: device, package: nil, desktop: false, title: device.displayName, icon: nil)
            return
        }
        show(device, package: nil, desktop: false)
    }

    /// 在獨立視窗（虛擬顯示器）執行 App
    /// at：視窗左上角放在這個螢幕位置（從 App 列拖出來放開的地方）
    func openApp(_ device: Device, package: String, at point: NSPoint? = nil) {
        let catalog = DeviceManager.shared.catalog(for: device)
        if AppSettings.shared.appWindowDockMode == .separate, !ChildMode.isChild {
            DockLauncher.launch(device: device, package: package, desktop: false,
                                title: catalog.label(for: package), icon: catalog.icon(for: package), at: point)
            return
        }
        let label = catalog.apps.isEmpty ? nil : catalog.label(for: package)
        show(device, package: package, desktop: false, label: label, at: point)
    }

    /// 桌面模式（虛擬顯示器 + 系統裝飾）
    func openDesktop(_ device: Device) {
        if AppSettings.shared.mirrorDockMode == .separate, !ChildMode.isChild {
            DockLauncher.launch(device: device, package: nil, desktop: true, title: "\(device.displayName) 桌面", icon: nil)
            return
        }
        show(device, package: nil, desktop: true)
    }

    /// 依啟動台設定開啟 App
    func launch(_ device: Device, package: String) {
        switch AppSettings.shared.launchTarget {
        case .separateWindow:
            openApp(device, package: package)
        case .mainDisplay:
            let k = key(device, nil)
            if let wc = open[k] {
                wc.model.launch(package)
                wc.window?.makeKeyAndOrderFront(nil)
            } else {
                Task { await DeviceManager.shared.catalog(for: device).launch(package) }
                openMirror(device)
            }
        }
    }

    func show(_ device: Device, package: String?, desktop: Bool, label: String? = nil, at point: NSPoint? = nil) {
        let k = key(device, package, desktop: desktop)
        if let wc = open[k] {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = MirrorModel(device: device, appPackage: package, desktopMode: desktop)
        model.appLabel = label
        let wc = MirrorWindowController(model: model, topLeft: point)
        wc.onClose = { [weak self] in
            self?.open[k] = nil
            if ChildMode.isChild, self?.open.isEmpty == true { NSApp.terminate(nil) }
        }
        open[k] = wc
        wc.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func isOpen(_ device: Device) -> Bool { open.keys.contains { $0.hasPrefix(device.id + "#") } }
}
