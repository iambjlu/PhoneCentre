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

    /// 喚醒 → 上滑 → 輸入密碼 → Enter
    @MainActor
    static func unlock(_ device: Device, session: ScrcpySession?) async -> Bool {
        guard await authenticate(reason: "填入「\(device.displayName)」的解鎖密碼"),
              let pw = AppSettings.shared.secret(secretKey(device)) else { return false }
        let c = device.client
        _ = try? await c.shell("input keyevent 224")
        try? await Task.sleep(nanoseconds: 400_000_000)
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
            _ = try? await c.shell("wm dismiss-keyguard; input swipe 540 1800 540 600 150")
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        if let s = session, pw.allSatisfy({ $0.isASCII }) {
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
