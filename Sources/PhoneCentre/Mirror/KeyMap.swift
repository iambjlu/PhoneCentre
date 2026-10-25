import AppKit

/// Mac 實體按鍵（virtual keyCode，與鍵盤配置／輸入法無關）→ Android KeyEvent keycode
enum KeyMap {
    static let back: Int32 = 4, home: Int32 = 3, appSwitch: Int32 = 187, menu: Int32 = 82
    static let enter: Int32 = 66, del: Int32 = 67, forwardDel: Int32 = 112, tab: Int32 = 61, space: Int32 = 62
    static let up: Int32 = 19, down: Int32 = 20, left: Int32 = 21, right: Int32 = 22
    static let moveHome: Int32 = 122, moveEnd: Int32 = 123, pageUp: Int32 = 92, pageDown: Int32 = 93
    static let volumeUp: Int32 = 24, volumeDown: Int32 = 25, power: Int32 = 26, wakeup: Int32 = 224

    static let table: [UInt16: Int32] = [
        // 字母
        0x00: 29, 0x0B: 30, 0x08: 31, 0x02: 32, 0x0E: 33, 0x03: 34, 0x05: 35, 0x04: 36, 0x22: 37,
        0x26: 38, 0x28: 39, 0x25: 40, 0x2E: 41, 0x2D: 42, 0x1F: 43, 0x23: 44, 0x0C: 45, 0x0F: 46,
        0x01: 47, 0x11: 48, 0x20: 49, 0x09: 50, 0x0D: 51, 0x07: 52, 0x10: 53, 0x06: 54,
        // 數字
        0x1D: 7, 0x12: 8, 0x13: 9, 0x14: 10, 0x15: 11, 0x17: 12, 0x16: 13, 0x1A: 14, 0x1C: 15, 0x19: 16,
        // 符號
        0x1B: 69, 0x18: 70, 0x21: 71, 0x1E: 72, 0x2A: 73, 0x29: 74, 0x27: 75, 0x2C: 76, 0x32: 68,
        0x2B: 55, 0x2F: 56,
        // 控制鍵
        0x24: enter, 0x4C: enter, 0x33: del, 0x75: forwardDel, 0x30: tab, 0x31: space,
        0x35: back,   // Esc = 返回
        0x7B: left, 0x7C: right, 0x7D: down, 0x7E: up,
        0x73: moveHome, 0x77: moveEnd, 0x74: pageUp, 0x79: pageDown,
        // F 鍵
        0x7A: 131, 0x78: 132, 0x63: 133, 0x76: 134, 0x60: 135, 0x61: 136,
        0x62: 137, 0x64: 138, 0x65: 139, 0x6D: 140, 0x67: 141, 0x6F: 142,
        // 數字鍵盤
        0x52: 144, 0x53: 145, 0x54: 146, 0x55: 147, 0x56: 148, 0x57: 149, 0x58: 150, 0x59: 151,
        0x5B: 152, 0x5C: 153, 0x41: 158, 0x43: 155, 0x45: 157, 0x4B: 154, 0x4E: 156,
    ]

    static func meta(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var m: Int32 = 0
        if flags.contains(.shift) { m |= 0x1 | 0x40 }
        if flags.contains(.option) { m |= 0x2 | 0x10 }
        if flags.contains(.control) { m |= 0x1000 | 0x2000 }
        if flags.contains(.capsLock) { m |= 0x100000 }
        return m
    }

    /// Mac 輸入法模式下，NSTextInputClient 的指令 → Android keycode（含 shift）
    static func command(_ sel: Selector) -> (Int32, shift: Bool)? {
        switch NSStringFromSelector(sel) {
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": return (enter, false)
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": return (del, false)
        case "deleteForward:": return (forwardDel, false)
        case "insertTab:": return (tab, false)
        case "insertBacktab:": return (tab, true)
        case "cancelOperation:": return (back, false)
        case "moveLeft:": return (left, false)
        case "moveRight:": return (right, false)
        case "moveUp:": return (up, false)
        case "moveDown:": return (down, false)
        case "moveLeftAndModifySelection:": return (left, true)
        case "moveRightAndModifySelection:": return (right, true)
        case "moveUpAndModifySelection:": return (up, true)
        case "moveDownAndModifySelection:": return (down, true)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:": return (moveHome, false)
        case "moveToEndOfLine:", "moveToRightEndOfLine:": return (moveEnd, false)
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:": return (moveHome, true)
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:": return (moveEnd, true)
        case "pageUp:", "scrollPageUp:": return (pageUp, false)
        case "pageDown:", "scrollPageDown:": return (pageDown, false)
        default: return nil
        }
    }
}
