import AppKit
import Combine
import SwiftUI

/// 一個鏡像視窗的狀態：主螢幕鏡像，或是在虛擬顯示器上執行的單一 App
@MainActor
final class MirrorModel: ObservableObject {
    @Published var device: Device
    /// 非 nil 代表「獨立視窗 App」，在虛擬顯示器上執行
    let appPackage: String?
    /// 虛擬顯示器的桌面模式（有系統裝飾，類似 DeX）
    let desktopMode: Bool
    /// 子程序沒有 App 清單時，由主程式傳入的 App 名稱
    var appLabel: String?

    @Published var statusText: String? = "連線中…"
    @Published var toast: String?
    @Published var markedText = ""
    @Published var locked = false
    @Published var screenOff: Bool
    @Published var muted = false
    @Published var keyboardMode: KeyboardMode {
        didSet { view.keyboardMode = keyboardMode; AppSettings.shared.keyboardMode = keyboardMode }
    }
    @Published var videoOptions: VideoOptions
    @Published var frameSize: CGSize = .zero
    /// 桌面模式還沒開過任何 App
    @Published var desktopEmpty = true

    let view = MirrorView()
    let catalog: AppCatalog
    private(set) var session: ScrcpySession?
    private var userStopped = false
    private var retryTask: Task<Void, Never>?
    private var timers: [Timer] = []
    private var lastPasteboardCount = NSPasteboard.general.changeCount
    private var unlockPromptDismissed = false
    var onFrameSize: ((CGSize) -> Void)?

    var isAppWindow: Bool { appPackage != nil }
    var isVirtualDisplay: Bool { appPackage != nil || desktopMode }

    var title: String {
        if let p = appPackage { return "\(appLabel ?? catalog.label(for: p)) — \(device.displayName)" }
        if desktopMode { return "桌面模式 — \(device.displayName)" }
        return device.displayName
    }

    init(device: Device, appPackage: String? = nil, desktopMode: Bool = false) {
        self.device = device
        self.appPackage = appPackage
        self.desktopMode = desktopMode
        let s = AppSettings.shared
        screenOff = appPackage == nil && !desktopMode && s.turnScreenOffWhileMirroring
        keyboardMode = s.keyboardMode
        videoOptions = s.videoOptions(for: CacheManager.key(for: device))
        catalog = DeviceManager.shared.catalog(for: device)
        view.keyboardMode = keyboardMode
        view.onMarkedText = { [weak self] in self?.markedText = $0 }
        view.onDropFiles = { [weak self] urls in self?.drop(urls) }
    }

    // MARK: 連線

    func start() {
        userStopped = false
        retryTask?.cancel()
        statusText = "連線中…"
        let s = AppSettings.shared
        var cfg = MirrorConfig()
        cfg.video = videoOptions
        // 同一台手機只讓主鏡像視窗傳音訊，避免重複
        cfg.audio = s.audioEnabled && !isVirtualDisplay
        cfg.muteDevice = s.muteDeviceWhenForwarding
        cfg.clipboardSync = s.clipboardSync
        cfg.screenOff = screenOff
        if isVirtualDisplay {
            cfg.newDisplay = virtualDisplaySpec()
            cfg.systemDecorations = desktopMode
            cfg.startApp = appPackage
        }
        // 舊的 session 先拔掉回呼，避免它晚到的「已停止」事件被當成新連線中斷
        let hadOld = detachCurrentSession()
        let session = ScrcpySession(device: device, config: cfg)
        session.onState = { [weak self, weak session] st in
            guard let self, let session, self.session === session else { return }
            self.handle(st)
        }
        session.onFrameSize = { [weak self, weak session] size in
            guard let self, let session, self.session === session else { return }
            self.frameSize = size
            self.view.setFrameSize(video: size)
            self.onFrameSize?(size)
        }
        let v = view
        session.onSample = { sample, changed in v.enqueue(sample, formatChanged: changed) }
        session.onDeviceClipboard = { [weak self] text in
            // 自動同步或 ⌘C／⌘X 取得的手機剪貼簿 → Mac
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self?.lastPasteboardCount = pb.changeCount
        }
        view.session = session
        self.session = session
        if hadOld {
            // 等舊的 server 釋放硬體編碼器
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak session] in
                guard let self, let session, self.session === session else { return }
                session.start()
            }
        } else {
            session.start()
        }
        startTimers()
    }

    /// 虛擬顯示器大小：沿用手機螢幕比例與密度
    /// 使用者調整視窗後的虛擬顯示器大小（像素）與密度
    private var customDisplay: (px: CGSize, dpi: Int)?
    /// Mac 螢幕的 backing scale（非 Retina = 1、Retina = 2），由視窗提供
    var backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 1

    /// 視窗大小（點）→ 虛擬顯示器（像素、dpi）。
    /// 像素數 = Mac 螢幕實際顯示得出的像素（非 Retina 就是 1:1），密度 160 × scale，
    /// 讓 1 個 Mac 點 ≈ 1 個 Android dp：App 看起來跟手機上差不多大，但手機不用畫多餘的像素。
    private func displaySpec(points pt: CGSize) -> (px: CGSize, dpi: Int) {
        let scale = max(1, backingScale)
        var w = pt.width * scale, h = pt.height * scale
        var dpi = 160 * scale
        // 受「最大解析度」限制（不限制時最多 2560），縮小時密度一起降，介面比例不變
        let cap = CGFloat(videoOptions.maxSize > 0 ? videoOptions.maxSize : 2560)
        let longest = max(w, h)
        if longest > cap { let k = cap / longest; w *= k; h *= k; dpi *= k }
        // 取 8 的倍數時無條件捨去，避免比視窗大幾個像素而被縮放
        let px = CGSize(width: max(240, (w / 8).rounded(.down) * 8), height: max(240, (h / 8).rounded(.down) * 8))
        return (px, max(80, Int(dpi.rounded())))
    }

    /// 虛擬顯示器規格：預設依螢幕大小推算視窗大小；調整過視窗就用視窗大小
    private func virtualDisplaySpec() -> String {
        let spec: (px: CGSize, dpi: Int)
        if let c = customDisplay {
            spec = c
        } else {
            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            let pt: CGSize
            if desktopMode {
                // 桌面模式：橫向，約螢幕的 75%
                pt = CGSize(width: screen.width * 0.75 - MirrorLayout.railWidth, height: screen.height * 0.75 - MirrorLayout.toolbarHeight)
            } else {
                // 單一 App：沿用手機長寬比，高度約螢幕的 80%
                let parts = (device.info?.screenSize ?? "").split(separator: "x").compactMap { Double($0) }
                let aspect = parts.count == 2 ? min(parts[0], parts[1]) / max(parts[0], parts[1]) : 0.47
                let h = screen.height * 0.8 - MirrorLayout.toolbarHeight
                pt = CGSize(width: h * aspect, height: h)
            }
            spec = displaySpec(points: pt)
        }
        return "\(Int(spec.px.width))x\(Int(spec.px.height))/\(spec.dpi)"
    }

    /// 使用者放開視窗邊框：依新的大小重建虛擬顯示器
    func resizeVirtualDisplay(toPoints pt: CGSize) {
        guard isVirtualDisplay, pt.width > 50, pt.height > 50 else { return }
        let spec = displaySpec(points: pt)
        let current = customDisplay?.px ?? frameSize
        if abs(current.width - spec.px.width) < 16, abs(current.height - spec.px.height) < 16 { return }
        customDisplay = spec
        statusText = "調整大小中…"
        start()
    }

    private func handle(_ st: ScrcpySession.State) {
        switch st {
        case .starting: statusText = "連線中…"
        case .running: statusText = nil
        case .failed(let msg):
            statusText = "連線中斷：\(msg)"
            scheduleRetry()
        case .stopped:
            if !userStopped { statusText = "連線中斷"; scheduleRetry() }
        case .idle: break
        }
    }

    /// 自動維持連線：裝置回來就重連
    private func scheduleRetry() {
        guard !userStopped, AppSettings.shared.keepAlive else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            for attempt in 1...600 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, !self.userStopped else { return }
                self.statusText = "連線中斷，等待裝置重新連線…（第 \(attempt) 次）"
                if await self.deviceIsOnline() {
                    self.start()
                    return
                }
            }
        }
    }

    private func deviceIsOnline() async -> Bool {
        let ep = device.endpoint, serial = device.serial
        let text = try? await Task.detached { try AdbSocket.hostQuery(ep, "host:devices-l") }.value
        return Device.parse(text ?? "", endpoint: ep).contains { $0.serial == serial && $0.isOnline }
    }

    func restart() {
        view.clear()
        start()
    }

    @discardableResult
    private func detachCurrentSession() -> Bool {
        guard let old = session else { return false }
        old.onState = nil
        old.onFrameSize = nil
        old.onSample = nil
        old.onDeviceClipboard = nil
        old.stop()
        session = nil
        return true
    }

    func stop() {
        userStopped = true
        retryTask?.cancel()
        timers.forEach { $0.invalidate() }
        timers = []
        detachCurrentSession()
    }

    // MARK: 定時工作：剪貼簿、鎖定畫面、App 列

    private func startTimers() {
        timers.forEach { $0.invalidate() }
        timers = []
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncMacClipboard() }
        })
        // 主鏡像與桌面模式都有左側 App 列，需要定時更新
        if !isAppWindow {
            timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollStatus() }
            })
            Task { await pollStatus() }
        }
    }

    private func syncMacClipboard() {
        guard AppSettings.shared.clipboardSync, let session, session.state == .running else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        if let s = pb.string(forType: .string) { session.setClipboard(s, paste: false) }
    }

    private func pollStatus() async {
        await catalog.refreshTasks()
        // 鎖定畫面只會出現在主螢幕
        guard !desktopMode, AppSettings.shared.offerTouchIDUnlock, view.window?.isKeyWindow == true else { return }
        let l = await LockScreenHelper.isLocked(device.client)
        if l != locked {
            locked = l
            if !l { unlockPromptDismissed = false }
        }
    }

    var showUnlockBanner: Bool { locked && !unlockPromptDismissed && AppSettings.shared.offerTouchIDUnlock }

    func dismissUnlock() { unlockPromptDismissed = true; objectWillChange.send() }

    func unlock() {
        Task {
            toast = "正在解鎖…"
            let ok = await LockScreenHelper.unlock(device, session: session)
            toast = ok ? nil : "解鎖未成功，請確認儲存的密碼"
            if ok { locked = false }
            clearToastLater()
        }
    }

    // MARK: 操作

    func key(_ code: Int32) { view.tapKey(code) }

    func toggleScreenOff() {
        screenOff.toggle()
        session?.send(.setDisplayPower(!screenOff))
    }

    func toggleMute() {
        muted.toggle()
        session?.audioVolume = muted ? 0 : 1
    }

    func launch(_ pkg: String) {
        desktopEmpty = false
        session?.send(.startApp(pkg))
    }

    func screenshot() {
        Task {
            guard let data = try? await device.client.exec("screencap -p", timeout: 20), !data.isEmpty else {
                toast = "截圖失敗"; clearToastLater(); return
            }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(device.displayName) 截圖 \(f.string(from: Date())).png")
            try? data.write(to: url)
            toast = "已存到桌面：\(url.lastPathComponent)"
            clearToastLater()
        }
    }

    func applyVideoOptions(_ o: VideoOptions) {
        videoOptions = o
        AppSettings.shared.setVideoOptions(o, for: CacheManager.key(for: device))
        restart()
    }

    private func drop(_ urls: [URL]) {
        let d = device
        Task {
            await DropHandler.handle(urls, device: d) { [weak self] msg in self?.toast = msg }
            if urls.contains(where: { $0.pathExtension.lowercased() == "apk" }) { await catalog.reload() }
            clearToastLater()
        }
    }

    private func clearToastLater() {
        let current = toast
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if toast == current { toast = nil }
        }
    }
}
