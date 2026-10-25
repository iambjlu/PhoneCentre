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

    private static func drawPattern(_ seq: [Int], on c: AdbClient, in b: CGRect) async {
        func pt(_ n: Int) -> CGPoint {
            CGPoint(x: b.minX + b.width * (CGFloat((n - 1) % 3) + 0.5) / 3, y: b.minY + b.height * (CGFloat((n - 1) / 3) + 0.5) / 3)
        }
        guard let first = seq.first else { return }
        var cmds = ["input motionevent DOWN \(Int(pt(first).x)) \(Int(pt(first).y))"]
        for (a, b2) in zip(seq, seq.dropFirst()) {
            let p0 = pt(a), p1 = pt(b2)
            for i in 1...6 {
                let t = CGFloat(i) / 6
                cmds.append("input motionevent MOVE \(Int(p0.x + (p1.x - p0.x) * t)) \(Int(p0.y + (p1.y - p0.y) * t))")
            }
        }
        let last = pt(seq.last!)
        cmds.append("input motionevent UP \(Int(last.x)) \(Int(last.y))")
        _ = try? await c.shell(cmds.joined(separator: "; "), timeout: 15)
    }

    /// 喚醒 → 上滑 → 輸入密碼（或畫圖形）→ Enter。
    /// 獨立視窗（虛擬顯示器）的鏡像連線不能操作主螢幕，所以傳 session = nil 改走 adb input。
    @MainActor
    static func unlock(_ device: Device, session: ScrcpySession?) async -> Bool {
        // 子程序不碰鑰匙圈，也不自己驗證：請主程式（有鑰匙圈權限、做 Touch ID）代辦，只傳「要解鎖哪支手機」，密碼不經過任何通知
        if ChildMode.isChild { return await requestUnlockFromMain(device) }
        return await unlockHere(device, session: session)
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
    private static func unlockHere(_ device: Device, session: ScrcpySession?) async -> Bool {
        guard await authenticate(reason: "填入「\(device.displayName)」的解鎖密碼"),
              let pw = AppSettings.shared.secret(secretKey(device)) else { return false }
        let c = device.client
        _ = try? await c.shell("input keyevent 224")
        try? await Task.sleep(nanoseconds: 400_000_000)
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
        if isPattern(pw) {
            let bounds = await patternBounds(c, screen: screen)
            await drawPattern(patternSequence(pw), on: c, in: bounds)
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
