import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        if ChildMode.isChild {
            ChildMode.bootstrap()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        CacheManager.shared.start()
        PhoneDataStore.shared.start()
        DeviceManager.shared.start()
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
            w.contentView = hosting
            w.minSize = NSSize(width: 1020, height: 830)
            // 視窗底層墊一層真正的桌面模糊（NSVisualEffectView）；SwiftUI 內容保持系統預設、不加自訂底色
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.frame = w.contentView?.superview?.bounds ?? .zero
            blur.autoresizingMask = [.width, .height]
            w.contentView?.superview?.addSubview(blur, positioned: .below, relativeTo: w.contentView)
            w.setFrameAutosaveName("MainWindow")
            if !w.setFrameUsingName("MainWindow") { w.center() }
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
