import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// 顯示手機畫面並把滑鼠／觸控板／鍵盤事件轉成 scrcpy 控制訊息
final class MirrorView: NSView, NSTextInputClient {
    weak var session: ScrcpySession?
    var keyboardMode: KeyboardMode = .macIME
    /// 拖放檔案進來
    var onDropFiles: (([URL]) -> Void)?
    /// 組字中文字變化（給外層顯示）
    var onMarkedText: ((String) -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var frameSize: CGSize = .zero

    // 觸控狀態
    private var fingerDown = false
    // 觸控板捲動 → 模擬手指拖曳
    private var scrollFinger: CGPoint?
    private var scrollAccum = CGSize.zero
    private var scrollAnchor: CGPoint = .zero
    // 雙指縮放
    private var pinchCenter: CGPoint?
    private var pinchScale: CGFloat = 1
    private var pinchBase: CGFloat = 0
    private static let pinchIds: (UInt64, UInt64) = (0x5043_0001, 0x5043_0002)
    private static let scrollId: UInt64 = 0x5043_0003

    private var marked = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func setFrameSize(video size: CGSize) {
        frameSize = size
    }

    func enqueue(_ sample: CMSampleBuffer, formatChanged: Bool) {
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed || formatChanged { r.flush() }
        r.enqueue(sample)
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: 座標

    /// 影像實際顯示區域（aspect fit）
    private var videoRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        let s = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let w = frameSize.width * s, h = frameSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// view 座標 → 裝置畫面座標
    private func devicePoint(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        let x = (p.x - r.minX) / r.width * frameSize.width
        let y = (p.y - r.minY) / r.height * frameSize.height
        return CGPoint(x: min(max(x, 0), frameSize.width - 1), y: min(max(y, 0), frameSize.height - 1))
    }

    private var viewToDeviceScale: CGFloat {
        let r = videoRect
        return r.width > 0 ? frameSize.width / r.width : 1
    }

    private func location(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func touch(_ action: ControlMessage.MotionAction, at p: CGPoint, pointer: UInt64 = ControlMessage.pointerFinger) {
        guard frameSize.width > 0 else { return }
        session?.send(.touch(action: action, pointer: pointer, x: Int32(p.x), y: Int32(p.y),
                             width: UInt16(frameSize.width), height: UInt16(frameSize.height),
                             pressure: action == .up ? 0 : 1, actionButton: 0, buttons: 0))
    }

    // MARK: 滑鼠

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        fingerDown = true
        touch(.down, at: devicePoint(location(e)))
    }

    override func mouseDragged(with e: NSEvent) {
        guard fingerDown else { return }
        touch(.move, at: devicePoint(location(e)))
    }

    override func mouseUp(with e: NSEvent) {
        guard fingerDown else { return }
        fingerDown = false
        touch(.up, at: devicePoint(location(e)))
    }

    // 右鍵 = 返回（螢幕關閉時則點亮）
    override func rightMouseDown(with e: NSEvent) {
        if let onBack { onBack() } else { session?.send(.backOrScreenOn(.down)) }
    }
    override func rightMouseUp(with e: NSEvent) {
        if onBack == nil { session?.send(.backOrScreenOn(.up)) }
    }

    // 中鍵 = 主畫面
    override func otherMouseDown(with e: NSEvent) { if let onHome { onHome() } else { sendKey(KeyMap.home, .down) } }
    override func otherMouseUp(with e: NSEvent) { if onHome == nil { sendKey(KeyMap.home, .up) } }

    // MARK: 捲動

    override func scrollWheel(with e: NSEvent) {
        let p = devicePoint(location(e))
        guard e.hasPreciseScrollingDeltas else {
            // 一般滑鼠滾輪：送捲動事件
            session?.send(.scroll(x: Int32(p.x), y: Int32(p.y), width: UInt16(frameSize.width), height: UInt16(frameSize.height),
                                  h: Float(e.scrollingDeltaX), v: Float(e.scrollingDeltaY), buttons: 0))
            return
        }
        // 觸控板：模擬單指拖曳，讓 Android 自己算慣性，手感跟手機一樣。慣性階段的事件忽略。
        if !e.momentumPhase.isEmpty { return }
        switch e.phase {
        case .began, .mayBegin:
            scrollAnchor = p
            scrollAccum = .zero
            scrollFinger = nil
        case .changed:
            let s = viewToDeviceScale
            scrollAccum.width += e.scrollingDeltaX * s
            scrollAccum.height += e.scrollingDeltaY * s
            let pos = CGPoint(x: clampX(scrollAnchor.x + scrollAccum.width), y: clampY(scrollAnchor.y + scrollAccum.height))
            if scrollFinger == nil {
                // 移動夠多才放下手指，避免誤觸成點擊
                guard hypot(scrollAccum.width, scrollAccum.height) > 6 * s else { return }
                touch(.down, at: scrollAnchor, pointer: Self.scrollId)
            }
            scrollFinger = pos
            touch(.move, at: pos, pointer: Self.scrollId)
        case .ended, .cancelled:
            if let f = scrollFinger { touch(.up, at: f, pointer: Self.scrollId) }
            scrollFinger = nil
        default:
            break
        }
    }

    private func clampX(_ x: CGFloat) -> CGFloat { min(max(x, 0), frameSize.width - 1) }
    private func clampY(_ y: CGFloat) -> CGFloat { min(max(y, 0), frameSize.height - 1) }

    // MARK: 雙指縮放（以指標位置為中心）

    override func magnify(with e: NSEvent) {
        switch e.phase {
        case .began:
            let c = devicePoint(location(e))
            pinchCenter = c
            pinchScale = 1
            pinchBase = max(min(frameSize.width, frameSize.height) * 0.12, 60)
            let (a, b) = pinchPoints()
            touch(.down, at: a, pointer: Self.pinchIds.0)
            touch(.down, at: b, pointer: Self.pinchIds.1)
        case .changed:
            guard pinchCenter != nil else { return }
            pinchScale = max(0.1, pinchScale + e.magnification)
            let (a, b) = pinchPoints()
            touch(.move, at: a, pointer: Self.pinchIds.0)
            touch(.move, at: b, pointer: Self.pinchIds.1)
        case .ended, .cancelled:
            guard pinchCenter != nil else { return }
            let (a, b) = pinchPoints()
            touch(.up, at: b, pointer: Self.pinchIds.1)
            touch(.up, at: a, pointer: Self.pinchIds.0)
            pinchCenter = nil
        default:
            break
        }
    }

    private func pinchPoints() -> (CGPoint, CGPoint) {
        guard let c = pinchCenter else { return (.zero, .zero) }
        let half = pinchBase * pinchScale / 2
        // 斜向擺放兩指，靠近邊緣時也比較不會被擠壓
        let dx = half * 0.7071, dy = half * 0.7071
        return (CGPoint(x: clampX(c.x - dx), y: clampY(c.y - dy)),
                CGPoint(x: clampX(c.x + dx), y: clampY(c.y + dy)))
    }

    // MARK: 鍵盤

    /// 虛擬顯示器的視窗：返回／主畫面要作用在該顯示器上，由 MirrorModel 接手（nil = 直接送 scrcpy）
    var onBack: (() -> Void)?
    var onHome: (() -> Void)?

    func sendKey(_ code: Int32, _ action: ControlMessage.KeyAction, meta: Int32 = 0, repeat rep: Int32 = 0) {
        session?.send(.keycode(action: action, keycode: code, repeat: rep, meta: meta))
    }

    func tapKey(_ code: Int32, meta: Int32 = 0) {
        sendKey(code, .down, meta: meta)
        sendKey(code, .up, meta: meta)
    }

    /// 實體按鍵模式時不給輸入法處理
    override var inputContext: NSTextInputContext? {
        keyboardMode == .physical ? nil : super.inputContext
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown, e.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: e)
        }
        return handleCommandShortcut(e)
    }

    /// ⌘ 快捷鍵：剪貼簿、全選、復原、Home/End 等
    private func handleCommandShortcut(_ e: NSEvent) -> Bool {
        let ctrl: Int32 = 0x1000 | 0x2000
        switch e.keyCode {
        case 0x09:   // V
            if let s = NSPasteboard.general.string(forType: .string) { session?.setClipboard(s, paste: true) }
            return true
        case 0x08:   // C
            session?.send(.getClipboard(copyKey: 1)); return true
        case 0x07:   // X
            session?.send(.getClipboard(copyKey: 2)); return true
        case 0x00:   // A
            tapKey(29, meta: ctrl); return true
        case 0x06:   // Z
            tapKey(54, meta: e.modifierFlags.contains(.shift) ? ctrl | 0x41 : ctrl); return true
        case 0x7B: tapKey(KeyMap.moveHome, meta: KeyMap.meta(e.modifierFlags)); return true
        case 0x7C: tapKey(KeyMap.moveEnd, meta: KeyMap.meta(e.modifierFlags)); return true
        case 0x33: if let onHome { onHome() } else { tapKey(KeyMap.home) }; return true       // ⌘⌫ = 主畫面
        default: return false   // 交給選單（⌘W 等）
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            if !handleCommandShortcut(e) { super.keyDown(with: e) }
            return
        }
        if keyboardMode == .macIME {
            // Ctrl 組合鍵直接送實體鍵
            if !e.modifierFlags.contains(.control), inputContext?.handleEvent(e) == true { return }
        }
        guard let code = KeyMap.table[e.keyCode] else { return }
        sendKey(code, .down, meta: KeyMap.meta(e.modifierFlags), repeat: e.isARepeat ? 1 : 0)
    }

    override func keyUp(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { return }
        // 輸入法模式下，按鍵按下時已由 insertText／doCommand 送出完整事件
        if keyboardMode == .macIME, !e.modifierFlags.contains(.control) { return }
        guard let code = KeyMap.table[e.keyCode] else { return }
        sendKey(code, .up, meta: KeyMap.meta(e.modifierFlags))
    }

    // MARK: NSTextInputClient（Mac 輸入法）

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        setMarked("")
        guard !s.isEmpty else { return }
        injectText(s)
    }

    /// ASCII 用 INJECT_TEXT；中文等非 ASCII 透過剪貼簿貼上（Android 的 KeyCharacterMap 無法直接注入）
    func injectText(_ s: String) {
        if s.allSatisfy({ $0.isASCII }) {
            session?.send(.text(s))
        } else {
            session?.setClipboard(s, paste: true)
        }
    }

    override func doCommand(by sel: Selector) {
        guard let (code, shift) = KeyMap.command(sel) else { return }
        tapKey(code, meta: shift ? 0x41 : 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setMarked((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
    }

    private func setMarked(_ s: String) {
        marked = s
        onMarkedText?(s)
    }

    func unmarkText() { setMarked("") }
    func selectedRange() -> NSRange { NSRange(location: marked.utf16.count, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// 選字視窗出現在畫面下方中央
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = videoRect
        let local = NSRect(x: r.midX - 100, y: r.maxY - 90, width: 200, height: 24)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    // MARK: 拖放

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
