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
    @Published var status = DeviceStatus()
    /// 第一次讀到手機狀態之前為 false（此時狀態環只轉圈圈，不顯示預設的錯誤資訊）
    @Published var statusLoaded = false
    /// 截圖時的白閃（1 → 0 淡出）
    @Published var flashOpacity = 0.0
    /// 由視窗控制器提供：關閉這個視窗
    var onCloseWindow: (() -> Void)?
    /// 由視窗控制器提供：隱藏這個視窗（連線與虛擬顯示器繼續，App 還在原本的顯示器上）
    var onHideWindow: (() -> Void)?
    /// 獨立視窗的 App 在手機上被關掉了（例如在主螢幕滑掉）
    @Published var appClosed = false {
        didSet { if appClosed, !oldValue { closedSnapshot = session?.decoder.lastGoodFrame } }
    }
    /// App 被關掉時顯示的最後一幀（毛玻璃霧化）
    @Published var closedSnapshot: NSImage?
    private var appSeen = false
    /// 啟動前 App 的程序就已經在跑（例如從主螢幕拖出來）：搬到新顯示器後密度不同，要重新啟動畫面
    private var appWasRunning = false
    private var lastSnapshotRequest = Date.distantPast
    private var emptyChecks = 0
    /// 這個視窗的虛擬顯示器 id（主螢幕鏡像為 nil）
    private(set) var displayId: Int?
    /// 已被某個鏡像視窗認領的虛擬顯示器，避免多個視窗大小相同時認錯
    private static var claimedDisplays = Set<Int>()
    /// 調整大小時，舊的 session 先留著，等 App 搬到新顯示器才關閉
    private var retiring: (session: ScrcpySession, display: Int?)?
    /// 虛擬顯示器旋轉（寬高對調）時由視窗控制器實作
    var onRotateWindow: (() -> Void)?

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
        if isVirtualDisplay {
            view.onBack = { [weak self] in self?.navBack() }
            // 中鍵／⌘⌫：桌面模式送 Home 到該桌面；單一 App 視窗不要因為誤按中鍵就關掉視窗
            if desktopMode { view.onHome = { [weak self] in self?.navHome() } }
        }
    }

    // MARK: 連線

    /// handover = true：調整虛擬顯示器大小，舊 session 繼續撐著，新顯示器好了再把 App 搬過去
    func start(handover: Bool = false) {
        userStopped = false
        retryTask?.cancel()
        if !handover { statusText = pendingStatus ?? "連線中…"; pendingStatus = nil }
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
            cfg.startApp = handover ? nil : appPackage
        }
        // 舊的 session 先拔掉回呼，避免它晚到的「已停止」事件被當成新連線中斷
        if !handover, retiring == nil, let pkg = appPackage {
            let c = device.client
            Task { appWasRunning = !((try? await c.shell("pidof \(pkg)")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let hadOld: Bool
        if handover, let old = session {
            old.onState = nil; old.onFrameSize = nil; old.onSample = nil; old.onDeviceClipboard = nil
            retiring = (old, displayId)
            session = nil
            hadOld = false
        } else {
            hadOld = detachCurrentSession()
        }
        let session = ScrcpySession(device: device, config: cfg)
        session.decoder.keepLastFrame = isAppWindow
        session.onState = { [weak self, weak session] st in
            guard let self, let session, self.session === session else { return }
            self.handle(st)
        }
        session.onFrameSize = { [weak self, weak session] size in
            guard let self, let session, self.session === session else { return }
            let old = self.frameSize
            self.frameSize = size
            // 長寬比或解析度改變時，畫面會短暫黑屏到新畫面出現；先顯示提示
            if old != .zero, old != size, self.statusText == nil { self.showChange("正在變更解析度…", seconds: 0.8) }
            self.view.setFrameSize(video: size)
            self.onFrameSize?(size)
        }
        let v = view
        session.onSample = { sample, changed in v.enqueue(sample, formatChanged: changed) }
        session.onDeviceClipboard = { [weak self] text in
            // 自動同步或 ⌘C／⌘X 取得的手機剪貼簿 → Mac（輸入法貼上文字期間不要蓋掉 Mac 的剪貼簿）
            guard let self, Date() > self.view.clipboardGuardUntil else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastPasteboardCount = pb.changeCount
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

    /// 依還原的視窗大小建立虛擬顯示器（第一次連線前呼叫）
    func presetDisplay(points pt: CGSize) { customDisplay = displaySpec(points: pt) }

    /// 使用者放開視窗邊框：依新的大小重建虛擬顯示器
    func resizeVirtualDisplay(toPoints pt: CGSize) {
        guard isVirtualDisplay, pt.width > 50, pt.height > 50 else { return }
        let spec = displaySpec(points: pt)
        let current = customDisplay?.px ?? frameSize
        if abs(current.width - spec.px.width) < 16, abs(current.height - spec.px.height) < 16 { return }
        customDisplay = spec
        if displayId != nil, session?.state == .running {
            showChange("正在調整視窗大小…", seconds: 8)
            start(handover: true)
        } else {
            pendingStatus = "正在調整視窗大小…"
            start()
        }
    }

    /// 虛擬顯示器旋轉：寬高對調
    func rotateVirtualDisplay() { showChange("正在變更方向…"); onRotateWindow?() }

    // MARK: 虛擬顯示器

    /// 連線完成後找出自己的虛擬顯示器；調整大小的話就把 App 從舊顯示器搬過來再關掉舊的
    private func finishConnect() async {
        let old = retiring
        let mine = await locateDisplay()
        if let old, let d = old.display { Self.claimedDisplays.remove(d) }
        if let mine { Self.claimedDisplays.insert(mine) }
        displayId = mine
        if old == nil, let app = appPackage, let mine { Task { await ensureAppOnDisplay(app, display: mine) } }
        guard let old else { return }
        retiring = nil
        if let from = old.display, let to = mine {
            // 搬完要確認舊顯示器上已經沒有 task 才關舊 session，不然 App 會掉回手機主螢幕（佔住主螢幕一段時間）
            for _ in 0..<4 {
                let tasks = await rootTasks(onDisplay: from)
                if tasks.isEmpty { break }
                for task in tasks {
                    _ = try? await device.client.shell("am display move-stack \(task) \(to)")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await nudgeDisplayConfig(to)
        } else if let app = appPackage {
            session?.send(.startApp(app))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        old.session.stop()
    }

    /// 讓虛擬顯示器上的 App 重新排版：把密度加 1 再改回來，等於觸發一次螢幕設定變更。
    /// App 在主螢幕與獨立視窗間切換後常停在舊的版面（跑版），這樣就會重繪。
    private func nudgeDisplayConfig(_ d: Int) async {
        let c = device.client
        // 顯示器不存在（例如剛被關掉）時，`wm density -d <id>` 會退回去操作主螢幕，把主螢幕的密度改掉再改回，
        // 主螢幕就會重排。所以先確認這個虛擬顯示器真的還在，而且絕不碰主螢幕（0）。
        guard d != 0, await displayExists(d) else { return }
        let out = (try? await c.shell("wm density -d \(d)")) ?? ""
        guard let line = out.split(separator: "\n").last(where: { $0.contains("density:") }),
              let dpi = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else { return }
        _ = try? await c.shell("wm density \(dpi + 1) -d \(d)")
        try? await Task.sleep(nanoseconds: 250_000_000)
        _ = try? await c.shell("wm density \(dpi) -d \(d)")
    }

    private func displayExists(_ d: Int) async -> Bool {
        let out = (try? await device.client.shell("dumpsys display | grep -c 'DisplayInfo{\"scrcpy\", displayId \(d)\"'")) ?? ""
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    /// 把 App 重新啟動（強制停止後在這個顯示器重開），讓它依這個顯示器的密度重新繪製。
    /// App 程序在別的密度的顯示器上跑過，光搬移 task 或送設定變更，它常停在舊的版面（太大或太小），
    /// 跟手動「關掉 App 再拖出來」是同樣的做法。
    private func redrawApp(_ pkg: String, display: Int) async {
        _ = try? await device.client.shell("am force-stop \(pkg)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        session?.send(.startApp(pkg))
    }

    /// 啟動後確認 App 真的在這個顯示器上。App 已經在主螢幕（或別的顯示器）執行時，
    /// 啟動指令可能只是把原本的 task 叫到前面，這邊的畫面會一直是黑的：找到那個 task 搬過來。
    private func ensureAppOnDisplay(_ pkg: String, display: Int) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard retiring == nil, !userStopped, displayId == display else { return }
            if !(await rootTasks(onDisplay: display)).isEmpty {
                if appWasRunning { appWasRunning = false; await redrawApp(pkg, display: display) } else { await nudgeDisplayConfig(display) }
                return
            }
            let out = (try? await device.client.shell("am stack list | grep -E '^RootTask id=|taskId='", timeout: 10)) ?? ""
            var root: Int?, rootDisplay: Int?
            var found: Int?
            for line in out.split(separator: "\n") {
                if line.hasPrefix("RootTask id=") {
                    root = Self.firstInt(in: line, after: "RootTask id=")
                    rootDisplay = Self.firstInt(in: line, after: "displayId=")
                } else if line.contains("taskId="), line.contains(": \(pkg)/"), let root, rootDisplay != display {
                    found = root
                }
            }
            if let found {
                _ = try? await device.client.shell("am display move-stack \(found) \(display)")
                try? await Task.sleep(nanoseconds: 600_000_000)
                appWasRunning = false
                await redrawApp(pkg, display: display)
            } else {
                session?.send(.startApp(pkg))
            }
        }
    }

    /// 關閉虛擬顯示器視窗前：把顯示器上的 App 送到主螢幕的背景。
    /// 由手機端輔助程式（`tobg`）在同一個程序裡搬移後立刻把主螢幕原本最上層的 task 拉回來，
    /// 兩個動作間隔不到 1ms，App 不會先在主螢幕上出現；輔助程式失敗才退回 `am` 指令。
    func sendAppsToBackground() async {
        guard isVirtualDisplay, let d = displayId else { return }
        let tasks = await rootTasks(onDisplay: d)
        guard !tasks.isEmpty else { return }
        let out = (try? await device.client.shell("dumpsys activity activities | grep -E 'Display #|mResumedActivity|taskId='")) ?? ""
        var inMain = false
        var prev: String?
        var prevTask: Int?
        for line in out.split(separator: "\n") {
            if line.contains("Display #") { inMain = line.contains("Display #0 "); continue }
            guard inMain else { continue }
            if prevTask == nil, line.trimmingCharacters(in: .whitespaces).hasPrefix("taskId=") {
                prevTask = Self.firstInt(in: line, after: "taskId=")
            }
            if prev == nil, line.contains("mResumedActivity"), let r = line.range(of: " u0 ") {
                prev = line[r.upperBound...].prefix { $0 != " " && $0 != "}" }.description
            }
        }
        let moved = (try? await HelperTool.shared.run(device, ["tobg", String(prevTask ?? -1)] + tasks.map(String.init), timeout: 10)) ?? ""
        var script: String
        if moved.contains("ok") {
            script = prevTask == nil && prev != nil ? "am start -n \(prev!) --activity-reorder-to-front" : ""
        } else {
            script = tasks.map { "am display move-stack \($0) 0" }.joined(separator: "; ")
            if let prev, !prev.isEmpty { script += "; am start -n \(prev) --activity-reorder-to-front" }
        }
        // App 回到背景後把它的程序收掉：下次在主螢幕打開時才會依主螢幕的密度重新繪製（不然會變超小）
        if let app = appPackage { script += (script.isEmpty ? "" : "; ") + "am kill \(app)" }
        if !script.isEmpty { _ = try? await device.client.shell(script, timeout: 10) }
    }

    /// 依大小與認領狀態找出這個視窗的虛擬顯示器（取 id 最大 = 最新建立的）
    private func locateDisplay() async -> Int? {
        let want = frameSize
        let out = (try? await device.client.shell("dumpsys display | grep 'mBaseDisplayInfo=DisplayInfo{\"scrcpy\"' | cut -c1-260")) ?? ""
        var best: Int?
        for line in out.split(separator: "\n") {
            guard let id = Self.firstInt(in: line, after: "displayId "), !Self.claimedDisplays.contains(id) || (id == displayId && retiring == nil),
                  let r = line.range(of: "real "),
                  let w = Self.firstInt(in: line[r.upperBound...], after: ""),
                  let hr = line.range(of: " x ", range: r.upperBound..<line.endIndex),
                  let h = Self.firstInt(in: line[hr.upperBound...], after: "") else { continue }
            if want == .zero || (abs(CGFloat(w) - want.width) < 2 && abs(CGFloat(h) - want.height) < 2) {
                best = max(best ?? 0, id)
            }
        }
        return best
    }

    private static func firstInt(in s: Substring, after marker: String) -> Int? {
        var rest = s
        if !marker.isEmpty { guard let r = s.range(of: marker) else { return nil }; rest = s[r.upperBound...] }
        return Int(rest.prefix { $0.isNumber })
    }

    /// 某個顯示器上的 root task id
    private func rootTasks(onDisplay id: Int) async -> [Int] {
        let out = (try? await device.client.shell("dumpsys activity activities | grep -E 'Display #|rootTaskId='", timeout: 15)) ?? ""
        var inDisplay = false
        var tasks: [Int] = []
        for line in out.split(separator: "\n") {
            if line.contains("Display #") { inDisplay = line.contains("Display #\(id) ") ; continue }
            if inDisplay, line.trimmingCharacters(in: .whitespaces).hasPrefix("taskId="),
               let r = line.range(of: "rootTaskId="), let t = Int(line[r.upperBound...].prefix { $0.isNumber }), !tasks.contains(t) {
                tasks.append(t)
            }
        }
        return tasks
    }

    private func handle(_ st: ScrcpySession.State) {
        switch st {
        case .starting: if retiring == nil, statusText == nil { statusText = "連線中…" }
        case .running:
            statusText = nil
            if isVirtualDisplay { Task { await finishConnect() } }
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

    private var pendingStatus: String?
    private var changeToken = 0

    /// 畫質、解析度、方向、視窗大小變更時，黑屏期間顯示的提示（連線好了會自動消失，最久 `seconds` 秒）
    func showChange(_ text: String, seconds: Double = 5) {
        changeToken += 1
        let token = changeToken
        statusText = text
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if changeToken == token, statusText == text { statusText = nil }
        }
    }

    func pendingChange(_ text: String) { pendingStatus = text }

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
        if let r = retiring { r.session.stop(); retiring = nil }
        if let d = displayId { Self.claimedDisplays.remove(d); displayId = nil }
        detachCurrentSession()
    }

    // MARK: 定時工作：剪貼簿、鎖定畫面、App 列

    private func startTimers() {
        timers.forEach { $0.invalidate() }
        timers = []
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncMacClipboard() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        })
        Task { await refreshStatus() }
        if isAppWindow {
            timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkAppAlive() }
            })
        }
        if isVirtualDisplay {
            // 手機鎖定時虛擬顯示器上的 App 會黑屏，要明確提示
            timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let l = await LockScreenHelper.isLocked(self.device.client)
                    if l != self.locked { self.locked = l }
                }
            })
        }
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

    /// 虛擬顯示器上已經沒有任何 task：App 被關掉了。連續兩次都沒有才算，避免啟動中的空檔誤判
    private func checkAppAlive() async {
        guard retiring == nil, session?.state == .running, let d = displayId else { return }
        let empty = await rootTasks(onDisplay: d).isEmpty
        if !empty {
            appSeen = true; emptyChecks = 0
            if appClosed { appClosed = false; closedSnapshot = nil }
            // 畫面靜止時編碼器不會產生新的關鍵幀，所以定期要一張，App 被關掉時才有最後一幀可以霧化
            if Date().timeIntervalSince(lastSnapshotRequest) > 6 {
                lastSnapshotRequest = Date()
                session?.send(.resetVideo)
            }
            return
        }
        // 已顯示「已關閉」，但使用者在手機上自己把這個 App 重新打開了（跑在主螢幕）：搬回這個視窗並收起提示
        if appClosed, let app = appPackage, await topResumedPackage() == app {
            appClosed = false; closedSnapshot = nil
            appSeen = false; emptyChecks = 0
            await ensureAppOnDisplay(app, display: d)
            return
        }
        emptyChecks += 1
        if appSeen, emptyChecks >= 2, !appClosed { appClosed = true }
    }

    /// 目前在手機最上層（resumed）的 App 套件名
    private func topResumedPackage() async -> String? {
        let out = (try? await device.client.shell("dumpsys activity activities | grep -m1 -E 'topResumedActivity=|mResumedActivity:'")) ?? ""
        guard let r = out.range(of: #"u\d+ [A-Za-z0-9_.]+/"#, options: .regularExpression) else { return nil }
        return out[r].split(separator: " ").last.map { String($0.dropLast()) }
    }

    func reopenApp() {
        guard let app = appPackage else { return }
        appClosed = false
        appSeen = false
        emptyChecks = 0
        session?.send(.startApp(app))
        if let d = displayId { Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await nudgeDisplayConfig(d) } }
    }

    private func refreshStatus() async {
        if let s = await DeviceStatus.fetch(device.client) {
            if s != status { status = s }
            statusLoaded = true
        }
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
            let ok = await LockScreenHelper.unlock(device, session: isVirtualDisplay ? nil : session)
            toast = ok ? nil : "解鎖未成功，請確認儲存的密碼"
            if ok { locked = false }
            clearToastLater()
        }
    }

    // MARK: 操作

    func key(_ code: Int32) { view.tapKey(code) }

    func showToast(_ text: String) { toast = text; clearToastLater() }

    /// 返回：虛擬顯示器上要指定顯示器，不然會作用在主螢幕
    func navBack() {
        if isVirtualDisplay, let d = displayId { inputKey(KeyMap.back, display: d) } else { key(KeyMap.back) }
    }

    /// 主畫面：主螢幕鏡像是 Home；獨立視窗＝關閉視窗（App 留在背景）；桌面模式送 Home 到該顯示器
    func navHome() {
        guard isVirtualDisplay else { key(KeyMap.home); return }
        if isAppWindow { onHideWindow?() }
        else if let d = displayId { inputKey(KeyMap.home, display: d) }
    }

    /// 最近使用：主螢幕走 scrcpy；桌面模式把 APP_SWITCH 送到該顯示器
    func navRecents() {
        if isVirtualDisplay, let d = displayId { inputKey(KeyMap.appSwitch, display: d) } else { key(KeyMap.appSwitch) }
    }

    func closeWindow() { onCloseWindow?() }
    func hideWindow() { onHideWindow?() }

    /// 強制停止 App 並關閉視窗
    func forceStopAndClose() {
        guard let pkg = appPackage else { return }
        Task {
            await catalog.forceStop(pkg)
            closeWindow()
        }
    }

    /// 結束程式（⌘Q）前：獨立 App 視窗跟導覽列的「結束」一樣強制停止 App；桌面模式把 App 送到背景。
    /// 不處理的話虛擬顯示器一關，App 會被系統搬回手機主螢幕
    func prepareForQuit() async {
        if let pkg = appPackage { await catalog.forceStop(pkg) }
        else if desktopMode { await sendAppsToBackground() }
    }

    private func inputKey(_ code: Int32, display: Int) {
        let c = device.client
        Task { _ = try? await c.shell("input -d \(display) keyevent \(code)") }
    }

    /// 鎖定方向：0 = 0°、1 = 90°、2 = 180°、3 = 270°
    func setRotation(_ r: Int) {
        showChange("正在變更方向…")
        status.autoRotate = false
        status.userRotation = r
        let c = device.client
        Task { _ = try? await c.shell("settings put system accelerometer_rotation 0; settings put system user_rotation \(r)") }
    }

    /// 強制所有 App 使用設定的方向：忽略 App 自己要求的方向（例如只支援直向的 App 也會跟著轉），
    /// 並讓畫面固定跟著使用者設定的旋轉。關閉就恢復各 App 自己決定。
    func setForceOrientation(_ on: Bool) {
        showChange("正在變更方向…")
        status.forceOrientation = on
        let c = device.client
        Task {
            _ = try? await c.shell("wm set-ignore-orientation-request \(on ? "true" : "false"); wm fixed-to-user-rotation \(on ? "enabled" : "default")")
        }
    }

    func setAutoRotate(_ on: Bool) {
        status.autoRotate = on
        let c = device.client
        Task { _ = try? await c.shell("settings put system accelerometer_rotation \(on ? 1 : 0)") }
    }

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
        flash()
        Task {
            guard let png = await captureScreenPNG() else {
                toast = "截圖失敗"; clearToastLater(); return
            }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(device.displayName) 截圖 \(f.string(from: Date())).png")
            do { try png.write(to: url) } catch { toast = "截圖失敗"; clearToastLater(); return }
            toast = "已存到桌面：\(url.lastPathComponent)"
            clearToastLater()
        }
    }

    /// 像 iPhone 截圖：先全白，再淡出
    private func flash() {
        flashOpacity = 1
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.5)) { self.flashOpacity = 0 } }
    }

    /// 主螢幕用 screencap；虛擬顯示器（或 screencap 失敗，例如 Android 14 對虛擬顯示器的 -d 無效）改取鏡像影像的關鍵幀
    private func captureScreenPNG() async -> Data? {
        if !isVirtualDisplay,
           let data = try? await device.client.exec("screencap -p", timeout: 20), Self.isPNG(data) { return data }
        if isVirtualDisplay, let d = displayId,
           let data = try? await device.client.exec("screencap -d \(d) -p", timeout: 20), Self.isPNG(data) { return data }
        return await session?.captureFrame()
    }

    private static func isPNG(_ d: Data) -> Bool { d.count > 100 && d.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

    func applyVideoOptions(_ o: VideoOptions) {
        videoOptions = o
        AppSettings.shared.setVideoOptions(o, for: CacheManager.key(for: device))
        pendingStatus = "正在變更畫質設定…"
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
