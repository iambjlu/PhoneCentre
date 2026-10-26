import Foundation
import LocalAuthentication

/// 偵測手機鎖定畫面，並用 Touch ID 驗證後自動輸入儲存在鑰匙圈的手機密碼
enum LockScreenHelper {
    static func secretKey(_ device: Device) -> String { "lock.\(CacheManager.key(for: device))" }

    static func hasPassword(_ device: Device) -> Bool { AppSettings.shared.secret(secretKey(device)) != nil }

    static func setPassword(_ pw: String?, for device: Device) {
        AppSettings.shared.setSecret(secretKey(device), pw)
    }

    /// 是否在鎖定畫面（keyguard 顯示中）
    static func isLocked(_ c: AdbClient) async -> Bool {
        let out = (try? await c.shell(
            "dumpsys window | grep -E 'mDreamingLockscreen=|mShowingLockscreen=|isKeyguardShowing=|mKeyguardShowing='; " +
            "dumpsys activity activities | grep -iE 'keyguardShowing=' | head -3", timeout: 5)) ?? ""
        let lower = out.lowercased()
        return lower.contains("dreaminglockscreen=true") || lower.contains("showinglockscreen=true")
            || lower.contains("keyguardshowing=true")
    }

    /// Touch ID（或 Mac 登入密碼）驗證
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static let patternPrefix = "pattern:"

    static func isPattern(_ pw: String) -> Bool { pw.hasPrefix(patternPrefix) }

    static func patternSequence(_ pw: String) -> [Int] { pw.dropFirst(patternPrefix.count).compactMap { $0.wholeNumberValue } }

    /// 螢幕大小（像素），用來算上滑與圖形密碼的座標
    private static func screenSize(_ device: Device) -> CGSize {
        let p = (device.info?.screenSize ?? "").split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: min(p[0], p[1]), height: max(p[0], p[1])) : CGSize(width: 1080, height: 2280)
    }

    /// 用 uiautomator 找圖形密碼的範圍；找不到就用螢幕下半部推測
    private static func patternBounds(_ c: AdbClient, screen: CGSize) async -> CGRect {
        let xml = (try? await c.shell("uiautomator dump /sdcard/pc_ui.xml >/dev/null 2>&1; cat /sdcard/pc_ui.xml; rm -f /sdcard/pc_ui.xml", timeout: 15)) ?? ""
        for node in xml.components(separatedBy: "<node ") where node.contains("LockPatternView") || node.lowercased().contains("lockpatternview") {
            if let r = node.range(of: "bounds=\"[") {
                let nums = node[r.upperBound...].prefix { $0 != "\"" }
                    .split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Double($0) }
                if nums.count == 4, nums[2] > nums[0], nums[3] > nums[1] {
                    return CGRect(x: nums[0], y: nums[1], width: nums[2] - nums[0], height: nums[3] - nums[1])
                }
            }
        }
        let w = screen.width * 0.8
        return CGRect(x: (screen.width - w) / 2, y: screen.height * 0.85 - w, width: w, height: w)
    }

    /// 圖形密碼每一點的座標（螢幕像素），每兩點之間補幾個點讓軌跡連續
    private static func patternPath(_ seq: [Int], in b: CGRect) -> [CGPoint] {
        func pt(_ n: Int) -> CGPoint {
            CGPoint(x: b.minX + b.width * (CGFloat((n - 1) % 3) + 0.5) / 3, y: b.minY + b.height * (CGFloat((n - 1) / 3) + 0.5) / 3)
        }
        guard let first = seq.first else { return [] }
        var pts = [pt(first)]
        for (a, b2) in zip(seq, seq.dropFirst()) {
            let p0 = pt(a), p1 = pt(b2)
            for i in 1...5 {
                let t = CGFloat(i) / 5
                pts.append(CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
            }
        }
        pts.append(pts.last!)
        return pts
    }

    /// 畫圖形：有主螢幕鏡像連線就直接送觸控（最快）；沒有就由手機端輔助程式在同一個程序內連續注入，
    /// 不再每一段都執行一次 `input`（每次都要啟動一個程序，約 0.1 秒）。輔助程式失敗才退回 `input motionevent`
    private static func drawPattern(_ seq: [Int], device: Device, session: ScrcpySession?, screen: CGSize, in b: CGRect) async {
        let pts = patternPath(seq, in: b)
        guard !pts.isEmpty else { return }
        if let s = session, s.frameSize.width > 0 {
            let size = s.frameSize
            let kx = size.width / screen.width, ky = size.height / screen.height
            let w = UInt16(size.width), h = UInt16(size.height)
            for (i, p) in pts.enumerated() {
                let action: ControlMessage.MotionAction = i == 0 ? .down : (i == pts.count - 1 ? .up : .move)
                s.send(.touch(action: action, pointer: ControlMessage.pointerFinger, x: Int32(p.x * kx), y: Int32(p.y * ky),
                              width: w, height: h, pressure: action == .up ? 0 : 1, actionButton: 0, buttons: 0))
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            return
        }
        let arg = pts.map { "\(Int($0.x)),\(Int($0.y))" }
        let out = (try? await HelperTool.shared.run(device, ["gesture", "8"] + arg, timeout: 15)) ?? ""
        if out.contains("ok") { return }
        var cmds = ["input motionevent DOWN \(arg[0].replacingOccurrences(of: ",", with: " "))"]
        cmds += arg.dropFirst().dropLast().map { "input motionevent MOVE \($0.replacingOccurrences(of: ",", with: " "))" }
        cmds.append("input motionevent UP \(arg.last!.replacingOccurrences(of: ",", with: " "))")
        _ = try? await device.client.shell(cmds.joined(separator: "; "), timeout: 20)
    }

    /// 找到過的圖形密碼範圍（依裝置），下次不用再跑一次很慢的 uiautomator；解鎖失敗就清掉重找
    @MainActor private static var patternCache: [String: CGRect] = [:]

    /// 手機面板關閉／開啟（手機本身保持開機）：自動填入密碼期間黑屏，旁人看不到圖形或數字。
    /// 有主螢幕鏡像連線就用 scrcpy 的面板電源；沒有就請手機端輔助程式處理
    private static func setPanel(_ on: Bool, device: Device, session: ScrcpySession?) async {
        if let s = session { s.send(.setDisplayPower(on)); return }
        _ = try? await HelperTool.shared.run(device, ["power", on ? "2" : "0"], timeout: 10)
    }

    /// 喚醒 → 上滑 → 輸入密碼（或畫圖形）→ Enter。
    /// 獨立視窗（虛擬顯示器）的鏡像連線不能操作主螢幕，所以傳 session = nil 改走 adb input。
    @MainActor
    static func unlock(_ device: Device, session: ScrcpySession?, keepScreenOff: Bool = false) async -> Bool {
        // 子程序不碰鑰匙圈，也不自己驗證：請主程式（有鑰匙圈權限、做 Touch ID）代辦，只傳「要解鎖哪支手機」，密碼不經過任何通知
        if ChildMode.isChild { return await requestUnlockFromMain(device) }
        return await unlockHere(device, session: session, keepScreenOff: keepScreenOff)
    }

    private static let requestName = Notification.Name("com.iambjlu.PhoneCentre.unlockRequest")
    private static let resultName = Notification.Name("com.iambjlu.PhoneCentre.unlockResult")

    /// 子程序：送出解鎖請求，等主程式回報結果（最久 90 秒，含 Touch ID 等待時間）
    @MainActor
    private static func requestUnlockFromMain(_ device: Device) async -> Bool {
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        return await withCheckedContinuation { cont in
            var finished = false
            var token: NSObjectProtocol?
            func finish(_ ok: Bool) {
                guard !finished else { return }
                finished = true
                if let token { center.removeObserver(token) }
                cont.resume(returning: ok)
            }
            token = center.addObserver(forName: resultName, object: nil, queue: .main) { n in
                guard n.userInfo?["id"] as? String == id else { return }
                finish(n.userInfo?["ok"] as? Bool ?? false)
            }
            center.postNotificationName(requestName, object: nil, userInfo: [
                "id": id, "serial": device.serial, "host": device.endpoint.host, "port": device.endpoint.port,
                "remote": device.endpoint.remoteID?.uuidString ?? "",
            ], deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { finish(false) }
        }
    }

    /// 主程式：接收子程序的解鎖請求
    @MainActor
    static func startServingUnlockRequests() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: requestName, object: nil, queue: .main) { n in
            guard let info = n.userInfo, let id = info["id"] as? String, let serial = info["serial"] as? String else { return }
            let remote = (info["remote"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor in
                var ok = false
                if let d = DeviceManager.shared.devices.first(where: { $0.serial == serial && $0.endpoint.remoteID == remote && $0.isOnline }) {
                    ok = await unlockHere(d, session: nil)
                }
                center.postNotificationName(resultName, object: nil, userInfo: ["id": id, "ok": ok], deliverImmediately: true)
            }
        }
    }

    @MainActor
    private static func unlockHere(_ device: Device, session: ScrcpySession?, keepScreenOff: Bool = false) async -> Bool {
        guard await authenticate(reason: "填入「\(device.displayName)」的解鎖密碼"),
              let pw = AppSettings.shared.secret(secretKey(device)) else { return false }
        var session = session, keepScreenOff = keepScreenOff
        // 獨立視窗或子程序來的請求：這支手機有開主螢幕鏡像的話，借用它的連線（觸控比較快，面板電源也由它管）
        if session == nil, let m = WindowManager.shared.open.values.map(\.model)
            .first(where: { !$0.isVirtualDisplay && $0.device.id == device.id && $0.session?.state == .running }) {
            session = m.session
            keepScreenOff = m.screenOff
        }
        let c = device.client
        _ = try? await c.shell("input keyevent 224")
        // 自動填入期間手機黑屏（只關面板，手機保持開機），解鎖完再打開
        await setPanel(false, device: device, session: session)
        defer {
            if !keepScreenOff { Task { await setPanel(true, device: device, session: session) } }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let screen = screenSize(device)
        let size = session?.frameSize ?? .zero
        if let s = session, size.width > 0 {
            // 透過鏡像連線上滑
            let w = UInt16(size.width), h = UInt16(size.height)
            let x = Int32(size.width / 2)
            let steps = 8
            s.send(.touch(action: .down, pointer: ControlMessage.pointerFinger, x: x, y: Int32(size.height * 0.85),
                          width: w, height: h, pressure: 1, actionButton: 0, buttons: 0))
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: 15_000_000)
                let y = size.height * (0.85 - 0.5 * CGFloat(i) / CGFloat(steps))
                s.send(.touch(action: .move, pointer: ControlMessage.pointerFinger, x: x, y: Int32(y),
                              width: w, height: h, pressure: 1, actionButton: 0, buttons: 0))
            }
            s.send(.touch(action: .up, pointer: ControlMessage.pointerFinger, x: x, y: Int32(size.height * 0.35),
                          width: w, height: h, pressure: 0, actionButton: 0, buttons: 0))
        } else {
            let x = Int(screen.width / 2)
            _ = try? await c.shell("wm dismiss-keyguard; input swipe \(x) \(Int(screen.height * 0.85)) \(x) \(Int(screen.height * 0.3)) 150")
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let cacheKey = CacheManager.key(for: device)
        if isPattern(pw) {
            let bounds: CGRect
            if let cached = patternCache[cacheKey] { bounds = cached } else { bounds = await patternBounds(c, screen: screen) }
            await drawPattern(patternSequence(pw), device: device, session: session, screen: screen, in: bounds)
            try? await Task.sleep(nanoseconds: 900_000_000)
            let ok = !(await isLocked(c))
            if ok { patternCache[cacheKey] = bounds } else { patternCache[cacheKey] = nil }
            return ok
        } else if let s = session, pw.allSatisfy({ $0.isASCII }) {
            s.send(.text(pw))
            s.send(.keycode(action: .down, keycode: KeyMap.enter, repeat: 0, meta: 0))
            s.send(.keycode(action: .up, keycode: KeyMap.enter, repeat: 0, meta: 0))
        } else {
            let escaped = pw.replacingOccurrences(of: " ", with: "%s")
            _ = try? await c.shell("input text \(Shell.quote(escaped)); input keyevent 66")
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return !(await isLocked(c))
    }
}
