import AppKit
import SwiftUI

/// 選單列圖示：快速取用已連線裝置，以及已開啟／最近使用的 App
@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private weak var delegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        popover.behavior = .transient
        let hc = NSHostingController(rootView: MenuBarView(
            openMain: { [weak self] in self?.popover.performClose(nil); delegate.showMainWindow() },
            openSettings: { [weak self] in self?.popover.performClose(nil); delegate.showSettings() },
            close: { [weak self] in self?.popover.performClose(nil) }))
        // 讓 popover 跟著 SwiftUI 內容調整大小（預設是 0，會看不到）
        hc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hc
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.image = NSImage(systemSymbolName: "iphone.gen3.radiowaves.left.and.right", accessibilityDescription: "PhoneCentre")
            it.button?.target = self
            it.button?.action = #selector(toggle)
            item = it
        } else if !visible, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

struct MenuBarView: View {
    @ObservedObject private var dm = DeviceManager.shared
    let openMain: () -> Void
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dm.onlineDevices.isEmpty {
                Text("沒有已連線的裝置").foregroundStyle(.secondary).padding(16)
            }
            ForEach(dm.onlineDevices) { d in
                MenuDeviceSection(device: d, catalog: dm.catalog(for: d), close: close)
                Divider()
            }
            HStack {
                Button("打開手機中心", action: openMain)
                Spacer()
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("設定")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("結束 PhoneCentre")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 360)
    }
}

/// 草稿樣式：裝置名稱、型號，下面一排 App 圖示（已開啟的下方有點）
struct MenuDeviceSection: View {
    let device: Device
    @ObservedObject var catalog: AppCatalog
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Circle().fill(.green).frame(width: 9, height: 9).padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName).font(.headline)
                    Text(device.subtitle.isEmpty ? device.serial : device.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close(); WindowManager.shared.openMirror(device) } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("鏡像畫面")
            }
            let apps = Array((catalog.running + catalog.recent).prefix(14))
            if !apps.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 7), alignment: .leading, spacing: 8) {
                    ForEach(apps, id: \.self) { pkg in
                        VStack(spacing: 3) {
                            AppIconView(catalog: catalog, package: pkg, size: 32)
                            Circle().fill(catalog.running.contains(pkg) ? Color.primary.opacity(0.7) : .clear)
                                .frame(width: 4, height: 4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { close(); WindowManager.shared.launch(device, package: pkg) }
                        .help(catalog.label(for: pkg))
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(12)
        .task(id: device.id) {
            if catalog.apps.isEmpty { await catalog.reload() }
            await catalog.refreshTasks()
        }
    }
}
