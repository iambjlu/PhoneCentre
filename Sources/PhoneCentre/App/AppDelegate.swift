import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 整個 App 固定用深色外觀：鏡像視窗的標題列、右側欄等都是照深色設計，亮色模式下標題列會和視窗按鈕疊在一起
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        if ChildMode.isChild {
            ChildMode.bootstrap()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        CacheManager.shared.start()
        PhoneDataStore.shared.start()
        LockScreenHelper.startServingUnlockRequests()
        DeviceManager.shared.start()
        DeviceStatusStore.shared.start()
        RemoteManager.shared.start()
        ShareServer.shared.apply()
        menuBar = MenuBarController(delegate: self)
        menuBar?.setVisible(AppSettings.shared.showMenuBarIcon)
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 主程式關掉視窗後仍留在選單列；子程序關掉視窗就結束
        ChildMode.isChild || !AppSettings.shared.showMenuBarIcon
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ChildMode.isChild {
            // 獨立視窗被「隱藏」後，點 Dock 圖示就叫回來
            for wc in WindowManager.shared.open.values { wc.window?.makeKeyAndOrderFront(nil) }
        } else if !flag {
            showMainWindow()
        }
        return true
    }

    /// ⌘Q：先把獨立 App 視窗的 App 強制停止（跟導覽列的「結束」一樣），最多等 6 秒再真的結束
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let models = WindowManager.shared.open.values.map(\.model).filter(\.isVirtualDisplay)
        guard !models.isEmpty else { return .terminateNow }
        var replied = false
        func reply() { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
        Task { @MainActor in
            for m in models { await m.prepareForQuit() }
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { reply() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for wc in WindowManager.shared.open.values { wc.model.stop() }
    }

    // MARK: 視窗

    @objc func showMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "PhoneCentre"
            w.isReleasedWhenClosed = false
            // 標準視窗與標準元件：用最新 SDK 連結，系統會自動套用 Liquid Glass（側邊欄、工具列、分頁、按鈕）
            w.isOpaque = false
            w.backgroundColor = .clear   // 視窗底部的系統材質才看得到後面的桌面
            let hosting = NSHostingView(rootView: MainView())
            // NSHostingView 預設會依 SwiftUI 內容改寫視窗的最小／最大大小，把下面設定的最小值蓋掉
            hosting.sizingOptions = []
            w.contentView = hosting
            w.minSize = Self.mainMinSize
            w.contentMinSize = Self.mainMinSize
            // 視窗底層墊一層真正的桌面模糊（NSVisualEffectView）；SwiftUI 內容保持系統預設、不加自訂底色
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.frame = w.contentView?.superview?.bounds ?? .zero
            blur.autoresizingMask = [.width, .height]
            w.contentView?.superview?.addSubview(blur, positioned: .below, relativeTo: w.contentView)
            w.delegate = self
            w.setFrameAutosaveName("MainWindow")
            if !w.setFrameUsingName("MainWindow") { w.center() }
            // 記住的大小比最小值還小（舊版存下來的）就放大，左上角不動
            if w.frame.width < Self.mainMinSize.width || w.frame.height < Self.mainMinSize.height {
                let f = w.frame
                let size = NSSize(width: max(f.width, Self.mainMinSize.width), height: max(f.height, Self.mainMinSize.height))
                w.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: false)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated {
                    guard let w else { return }
                    // 拖曳邊框時由 windowWillResize 擋住；這裡只處理程式或其他工具直接設定的大小
                    if !w.inLiveResize { Self.clampMainWindow(w) }
                    Self.lockSidebar(in: w)
                }
            }
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow {
            Self.lockSidebar(in: w)
            // SwiftUI 的分割視圖在顯示後才建立，稍後再鎖一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.lockSidebar(in: w) }
        }
    }

    static let mainMinSize = NSSize(width: 1020, height: 830)

    /// 拖曳主視窗邊框（任何一角）：到最小值就停住、不再縮小，視窗不會跑掉。
    /// SwiftUI 的 NavigationSplitView 會自己改寫視窗的最小大小，只設 minSize 擋不住
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === mainWindow else { return frameSize }
        return NSSize(width: max(frameSize.width, Self.mainMinSize.width), height: max(frameSize.height, Self.mainMinSize.height))
    }

    /// `minSize` 只限制使用者拖邊框；程式、視窗管理工具或輔助使用 API 直接設定大小時會繞過，所以縮放後再夾回最小值（左上角不動）
    static func clampMainWindow(_ w: NSWindow) {
        let f = w.frame
        guard f.width < mainMinSize.width - 0.5 || f.height < mainMinSize.height - 0.5 else { return }
        let size = NSSize(width: max(f.width, mainMinSize.width), height: max(f.height, mainMinSize.height))
        w.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }
    static let sidebarWidth: CGFloat = 236

    /// 側邊欄寬度鎖死：直接設定 NavigationSplitView 底層的 NSSplitViewItem（最小＝最大＝236、不能收合）。
    /// 只靠 SwiftUI 的 navigationSplitViewColumnWidth，側邊欄會在縮小視窗或重開後被縮掉
    static func lockSidebar(in window: NSWindow) {
        guard let root = window.contentView else { return }
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if let split = v as? NSSplitView, split.isVertical, split.subviews.count >= 2 {
                if let ctl = split.delegate as? NSSplitViewController, let item = ctl.splitViewItems.first {
                    if item.minimumThickness != sidebarWidth { item.minimumThickness = sidebarWidth }
                    if item.maximumThickness != sidebarWidth { item.maximumThickness = sidebarWidth }
                    if item.canCollapse { item.canCollapse = false }
                    if item.isCollapsed { item.isCollapsed = false }
                }
                // 新版系統的 subviews[0] 是延伸到側邊欄底下的全寬內容欄，要用分割項目的 view 才是真正的側邊欄
                let sidebarView = (split.delegate as? NSSplitViewController)?.splitViewItems.first?.viewController.view ?? split.subviews[0]
                if abs(sidebarView.frame.width - sidebarWidth) > 0.5 { split.setPosition(sidebarWidth, ofDividerAt: 0) }
                placeDividerBlocker(over: split, sidebar: sidebarView, in: window)
                return
            }
            stack.append(contentsOf: v.subviews)
        }
    }

    /// 分隔線上蓋一層透明擋板（放在視窗最上層的 theme frame，不能放進 NSSplitView，否則會被當成新的一欄）：
    /// 滑鼠按下、拖曳都被它吃掉，游標維持箭頭，側邊欄完全不能拖動
    private static func placeDividerBlocker(over split: NSSplitView, sidebar: NSView, in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        let x = split.convert(NSPoint(x: sidebar.convert(sidebar.bounds, to: split).maxX, y: 0), to: frameView).x
        let r = NSRect(x: x - 6, y: 0, width: 14, height: frameView.bounds.height)
        let blocker = frameView.subviews.first { $0 is DividerBlocker } ?? {
            let b = DividerBlocker(frame: r)
            b.autoresizingMask = [.height]
            frameView.addSubview(b, positioned: .above, relativeTo: nil)
            return b
        }()
        if blocker.frame != r { blocker.frame = r; window.invalidateCursorRects(for: blocker) }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "PhoneCentre 設定"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setMenuBarVisible(_ v: Bool) { menuBar?.setVisible(v) }

    // MARK: 選單

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "關於 PhoneCentre", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        if !ChildMode.isChild {
            appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",").target = self
            appMenu.addItem(withTitle: "顯示PhoneCentre", action: #selector(showMainWindow), keyEquivalent: "0").target = self
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "隱藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        NSApp.mainMenu = main
    }
}

/// 蓋在側邊欄分隔線上的透明擋板：接住滑鼠事件、不做任何事，游標一律是箭頭
private final class DividerBlocker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}
