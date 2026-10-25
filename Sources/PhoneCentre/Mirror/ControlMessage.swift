import Foundation

/// scrcpy 控制協定（client → device），格式依 scrcpy-server 3.3.4 的 ControlMessageReader（big-endian）
enum ControlMessage {
    enum KeyAction: UInt8 { case down = 0, up = 1 }
    enum MotionAction: UInt8 { case down = 0, up = 1, move = 2, cancel = 3, hoverMove = 7 }

    static let pointerMouse: UInt64 = UInt64(bitPattern: -1)
    static let pointerFinger: UInt64 = UInt64(bitPattern: -2)

    case keycode(action: KeyAction, keycode: Int32, repeat: Int32, meta: Int32)
    case text(String)
    case touch(action: MotionAction, pointer: UInt64, x: Int32, y: Int32, width: UInt16, height: UInt16,
               pressure: Float, actionButton: Int32, buttons: Int32)
    case scroll(x: Int32, y: Int32, width: UInt16, height: UInt16, h: Float, v: Float, buttons: Int32)
    case backOrScreenOn(KeyAction)
    case expandNotifications
    case expandSettings
    case collapsePanels
    case getClipboard(copyKey: UInt8)        // 0 none, 1 copy, 2 cut
    case setClipboard(sequence: UInt64, paste: Bool, text: String)
    case setDisplayPower(Bool)
    case rotateDevice
    case startApp(String)
    case resetVideo

    var data: Data {
        var d = Data()
        func u8(_ v: UInt8) { d.append(v) }
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
        func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { d.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((v >> UInt64(s)) & 0xff)) } }
        func str(_ s: String, lenBytes: Int = 4, max: Int = 300_000) {
            var bytes = Data(s.utf8)
            if bytes.count > max { bytes = bytes.prefix(max) }
            if lenBytes == 1 { u8(UInt8(min(bytes.count, 255))); bytes = bytes.prefix(255) } else { u32(UInt32(bytes.count)) }
            d.append(bytes)
        }
        // 浮點轉定點：u16 對應 [0,1]，i16 對應 [-1,1]
        func u16fp(_ f: Float) -> UInt16 { f >= 1 ? 0xffff : UInt16(max(0, f) * 65_536) }
        func i16fp(_ f: Float) -> UInt16 {
            let c = max(-1, min(1, f))
            let v = c >= 1 ? Int16.max : Int16(c * 32_768)
            return UInt16(bitPattern: v)
        }

        switch self {
        case let .keycode(action, keycode, rep, meta):
            u8(0); u8(action.rawValue); i32(keycode); i32(rep); i32(meta)
        case let .text(s):
            u8(1); str(s, max: 300)
        case let .touch(action, pointer, x, y, w, h, pressure, actionButton, buttons):
            u8(2); u8(action.rawValue); u64(pointer); i32(x); i32(y); u16(w); u16(h)
            u16(u16fp(pressure)); i32(actionButton); i32(buttons)
        case let .scroll(x, y, w, h, hs, vs, buttons):
            // server 端會把 [-1,1] 乘回 16
            u8(3); i32(x); i32(y); u16(w); u16(h); u16(i16fp(hs / 16)); u16(i16fp(vs / 16)); i32(buttons)
        case let .backOrScreenOn(a):
            u8(4); u8(a.rawValue)
        case .expandNotifications: u8(5)
        case .expandSettings: u8(6)
        case .collapsePanels: u8(7)
        case let .getClipboard(k): u8(8); u8(k)
        case let .setClipboard(seq, paste, text):
            u8(9); u64(seq); u8(paste ? 1 : 0); str(text)
        case let .setDisplayPower(on): u8(10); u8(on ? 1 : 0)
        case .rotateDevice: u8(11)
        case let .startApp(name): u8(16); str(name, lenBytes: 1)
        case .resetVideo: u8(17)
        }
        return d
    }
}
