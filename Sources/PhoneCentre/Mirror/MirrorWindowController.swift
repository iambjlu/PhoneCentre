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
    /// 主螢幕鏡像還原的畫面高度；第一次收到影像時依手機畫面比例算寬度
    private var savedMainVideoHeight: CGFloat?

    /// 視窗高度未滿 636（內容高度 < 608）時，右側欄移到視窗底部：寬度不佔、改佔底部一條的高度
    /// （只有橫向模式才會；直向模式右側欄永遠在右邊）
    private var compactNow: Bool {
        guard let c = window?.contentLayoutRect.size else { return false }
        let landscape = model.isVirtualDisplay ? c.width > c.height : model.frameSize.width > model.frameSize.height
        return landscape && c.height < MirrorLayout.compactContentHeight
    }
    private var chromeWidth: CGFloat { compactNow ? 0 : MirrorLayout.railWidth + 1 }
    private var chromeHeight: CGFloat { compactNow ? MirrorLayout.bottomBarHeight : MirrorLayout.toolbarHeight }

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
        // 標題列與右側欄後面的底：只在這兩塊鋪桌面模糊（毛玻璃），手機畫面區域是黑底、不鋪，省渲染資源
        if let theme = window.contentView?.superview, let content = window.contentView {
            func strip(_ frame: NSRect, _ mask: NSView.AutoresizingMask) {
                let blur = NSVisualEffectView(frame: frame)
                blur.material = .underWindowBackground
                blur.blendingMode = .behindWindow
                blur.state = .active
                blur.autoresizingMask = mask
                theme.addSubview(blur, positioned: .below, relativeTo: content)
            }
            let tb = theme.bounds.height - content.frame.height
            strip(NSRect(x: 0, y: content.frame.maxY, width: theme.bounds.width, height: tb), [.width, .minYMargin])
            strip(NSRect(x: theme.bounds.width - MirrorLayout.railWidth, y: 0, width: MirrorLayout.railWidth, height: theme.bounds.height),
                  [.minXMargin, .height])
        }
        window.tabbingMode = .disallowed
        window.contentMinSize = window.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: MirrorLayout.portraitMinFrameWidth, height: MirrorLayout.portraitMinFrameHeight)).size
        window.setFrameAutosaveName("Mirror.\(model.device.id).\(model.appPackage ?? (model.desktopMode ? "desktop" : "main"))")
        // 虛擬顯示器視窗（獨立 App、桌面模式）記住上次的大小：先還原大小，再依需要移到指定位置
        let restored = window.setFrameUsingName(window.frameAutosaveName)
        var restoredSize: CGSize?
        if restored, model.isVirtualDisplay {
            let c = window.contentLayoutRect.size
            restoredSize = CGSize(width: c.width - (MirrorLayout.railWidth + 1), height: c.height - MirrorLayout.toolbarHeight)
        }
        savedVideoSize = restoredSize
        // 主螢幕鏡像：記住上次的高度（寬度依手機畫面比例算），不要每次都回到預設大小
        if restored, !model.isVirtualDisplay {
            savedMainVideoHeight = window.contentLayoutRect.size.height - MirrorLayout.toolbarHeight
        }
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
        updateMinSize()
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
        updateMinSize()
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
            if !model.isVirtualDisplay, let h = savedMainVideoHeight, h > 200 {
                videoH = min(h, screen.height * 0.95 - chromeHeight)
            }
        }
        var videoW = videoH * aspect
        let maxW = screen.width * 0.9 - chromeWidth
        if videoW > maxW { videoW = maxW; videoH = videoW / aspect }
        var content = NSSize(width: (videoW + MirrorLayout.railWidth + 1).rounded(), height: (videoH + MirrorLayout.toolbarHeight).rounded())
        // 高度不到門檻：右側欄會移到底部橫條，影像區是整個寬度、下面多一條橫條
        if size.width > size.height && content.height < MirrorLayout.compactContentHeight {
            content = NSSize(width: videoW.rounded(), height: (videoH + MirrorLayout.bottomBarHeight).rounded())
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true, animate: sizedOnce)
        sizedOnce = true
    }

    /// 所有鏡像視窗的大小限制（含標題列）：橫向最小 636×364、直向最小 364×636
    private func minFrameSize(landscape: Bool) -> NSSize {
        landscape
            ? NSSize(width: MirrorLayout.landscapeMinFrameWidth, height: MirrorLayout.landscapeMinFrameHeight)
            : NSSize(width: MirrorLayout.portraitMinFrameWidth, height: MirrorLayout.portraitMinFrameHeight)
    }

    /// 橫向或直向：主螢幕鏡像看手機畫面的比例，虛擬顯示器視窗看視窗自己的形狀
    private func isLandscape(frame: NSSize? = nil) -> Bool {
        if !model.isVirtualDisplay, model.frameSize.width > 0, model.frameSize.height > 0 {
            return model.frameSize.width > model.frameSize.height
        }
        guard let window else { return false }
        let f = frame ?? window.frame.size
        return f.width > f.height
    }

    private func updateMinSize() {
        guard let window else { return }
        let f = minFrameSize(landscape: isLandscape())
        window.contentMinSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: f)).size
    }

    func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { updateMinSize() }
    }

    /// 主螢幕鏡像：縮放時維持影像比例；虛擬顯示器：自由調整；兩者都不能小於最小大小
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minF = minFrameSize(landscape: isLandscape(frame: frameSize))
        if model.isVirtualDisplay { return NSSize(width: max(frameSize.width, minF.width), height: max(frameSize.height, minF.height)) }
        let size = model.frameSize
        guard size.width > 0, size.height > 0 else { return NSSize(width: max(frameSize.width, minF.width), height: max(frameSize.height, minF.height)) }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let compact = size.width > size.height && content.height < MirrorLayout.compactContentHeight
        let cw = compact ? 0 : MirrorLayout.railWidth + 1
        let chh = compact ? MirrorLayout.bottomBarHeight : MirrorLayout.toolbarHeight
        var videoH = max(content.height - chh, 100)
        var videoW = videoH * size.width / size.height
        // 維持影像比例的同時不能小於最小大小：兩邊都放大到夠為止
        let minC = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: minF)).size
        let scale = max((minC.width - cw) / videoW, (minC.height - chh) / videoH, 1)
        videoW *= scale; videoH *= scale
        let fixed = NSSize(width: videoW + cw, height: videoH + chh)
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
