import AppKit
import Combine
import SwiftUI

/// 鏡像視窗：主螢幕鏡像依手機畫面比例調整；虛擬顯示器（獨立 App、桌面模式）可自由調整大小，
/// 放開邊框時依新的大小重建虛擬顯示器，App 會以新的長寬重新排版。
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    let model: MirrorModel
    var onClose: (() -> Void)?
    private var sizedOnce = false
    private var bag: Set<AnyCancellable> = []
    /// 使用者自己調整過大小後，不再依影像大小改視窗
    private var userResized = false
    /// 還原的視窗大小（扣掉右側欄）；有的話虛擬顯示器就依這個大小建立，不會被影像大小改掉
    private var savedVideoSize: CGSize?

    private var chromeWidth: CGFloat { MirrorLayout.railWidth + 1 }
    private var chromeHeight: CGFloat { MirrorLayout.toolbarHeight }

    @MainActor
    init(model: MirrorModel, topLeft: NSPoint? = nil) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.title
        window.isReleasedWhenClosed = false
        // 視窗透明，右側欄的毛玻璃才透得出桌面
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: MirrorContentView(model: model))
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 240 + MirrorLayout.railWidth, height: MirrorLayout.minContentHeight)
        window.setFrameAutosaveName("Mirror.\(model.device.id).\(model.appPackage ?? (model.desktopMode ? "desktop" : "main"))")
        // 虛擬顯示器視窗（獨立 App、桌面模式）記住上次的大小：先還原大小，再依需要移到指定位置
        let restored = window.setFrameUsingName(window.frameAutosaveName)
        var restoredSize: CGSize?
        if restored, model.isVirtualDisplay {
            let c = window.contentLayoutRect.size
            restoredSize = CGSize(width: c.width - (MirrorLayout.railWidth + 1), height: c.height - MirrorLayout.toolbarHeight)
        }
        savedVideoSize = restoredSize
        if let topLeft {
            window.setFrameTopLeftPoint(topLeft)
        } else if !restored {
            // 錯開排列，不要疊在目前的視窗正上方
            if let key = NSApp.keyWindow, key.isVisible {
                window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 40, y: key.frame.maxY - 40))
            } else {
                window.center()
            }
        }
        super.init(window: window)
        window.delegate = self
        model.onFrameSize = { [weak self] size in self?.fit(to: size) }
        model.onRotateWindow = { [weak self] in self?.rotateWindow() }
        model.onCloseWindow = { [weak self] in self?.window?.performClose(nil) }
        model.onHideWindow = { [weak self] in self?.window?.orderOut(nil) }
        // App 名稱載入後更新標題
        model.catalog.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.window?.title = self?.model.title ?? "" }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func show() {
        model.backingScale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        if let savedVideoSize, savedVideoSize.width > 100, savedVideoSize.height > 100 {
            userResized = true
            model.presetDisplay(points: savedVideoSize)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(model.view)
        model.start()
    }

    /// 依影像大小調整視窗（第一次或旋轉時）
    @MainActor
    private func fit(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        window.title = model.title
        // 虛擬顯示器的大小是依視窗決定的，使用者調整過後就不要反過來改視窗
        if model.isVirtualDisplay && userResized { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let current = window.contentLayoutRect.size
        let aspect = size.width / size.height
        var videoH: CGFloat
        if sizedOnce {
            // 旋轉：保持較長邊大約不變
            let oldVideo = CGSize(width: current.width - chromeWidth, height: current.height - chromeHeight)
            let longSide = max(oldVideo.width, oldVideo.height)
            videoH = aspect >= 1 ? longSide / aspect : longSide
        } else {
            videoH = model.isVirtualDisplay
                ? min(size.height / max(1, window.backingScaleFactor), screen.height * 0.9 - chromeHeight)
                : min(screen.height * 0.85 - chromeHeight, size.height)
        }
        var videoW = videoH * aspect
        let maxW = screen.width * 0.9 - chromeWidth
        if videoW > maxW { videoW = maxW; videoH = videoW / aspect }
        let content = NSSize(width: (videoW + chromeWidth).rounded(), height: (videoH + chromeHeight).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true, animate: sizedOnce)
        sizedOnce = true
    }

    /// 主螢幕鏡像：縮放時維持影像比例；虛擬顯示器：自由調整
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if model.isVirtualDisplay { return frameSize }
        let size = model.frameSize
        guard size.width > 0, size.height > 0 else { return frameSize }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let videoH = max(content.height - chromeHeight, 100)
        let videoW = videoH * size.width / size.height
        let fixed = NSSize(width: videoW + chromeWidth, height: videoH + chromeHeight)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: fixed)).size
    }

    /// 虛擬顯示器旋轉：視窗寬高對調，再依新的大小重建顯示器
    @MainActor
    private func rotateWindow() {
        guard let window else { return }
        let c = window.contentLayoutRect.size
        let video = CGSize(width: c.width - chromeWidth, height: c.height - chromeHeight)
        let content = NSSize(width: video.height + chromeWidth, height: video.width + chromeHeight)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
        userResized = true
        model.backingScale = window.backingScaleFactor
        let n = window.contentLayoutRect.size
        model.resizeVirtualDisplay(toPoints: CGSize(width: n.width - chromeWidth, height: n.height - chromeHeight))
    }

    /// 放開邊框：依新的視窗大小重建虛擬顯示器
    func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard model.isVirtualDisplay, let window else { return }
            userResized = true
            model.backingScale = window.backingScaleFactor
            let c = window.contentLayoutRect.size
            model.resizeVirtualDisplay(toPoints: CGSize(width: c.width - chromeWidth, height: c.height - chromeHeight))
        }
    }

    private var cleanedUp = false

    /// 虛擬顯示器視窗關閉前，先讓 App 回到背景再真正關閉
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if cleanedUp || !model.isVirtualDisplay { return true }
        Task { @MainActor in
            await model.sendAppsToBackground()
            cleanedUp = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.stop()
        }
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = window?.makeFirstResponder(model.view)
        }
    }
}
