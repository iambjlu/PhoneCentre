import Foundation

/// 簡訊（content://sms）
struct PhoneSMS: Codable, Identifiable, Hashable {
    var id: Int
    var address: String
    var date: Date
    var type: Int          // 1 收到、2 寄出，其他（草稿、發送中等）
    var read: Bool
    var body: String
    var isSent: Bool { type != 1 }
}

/// 通話記錄（content://call_log/calls）
struct PhoneCall: Codable, Identifiable, Hashable {
    var id: Int
    var number: String
    var name: String
    var date: Date
    var duration: Int      // 秒
    var type: Int          // 1 撥入、2 撥出、3 未接、4 語音信箱、5 拒接、6 封鎖
    var typeTitle: String {
        switch type {
        case 1: return "撥入"
        case 2: return "撥出"
        case 3: return "未接"
        case 4: return "語音信箱"
        case 5: return "已拒接"
        case 6: return "已封鎖"
        default: return "其他"
        }
    }
    var symbol: String {
        switch type {
        case 1: return "phone.arrow.down.left"
        case 2: return "phone.arrow.up.right"
        case 3, 5, 6: return "phone.down"
        default: return "phone"
        }
    }
    var isMissed: Bool { type == 3 || type == 5 || type == 6 }
}

/// 通知。`clearedAt == nil` 表示手機上還在；有值表示已被清掉（仍在保存期限內）
struct PhoneNotification: Codable, Identifiable, Hashable {
    var id: String
    var key: String            // 手機端的通知 key（含套件、id、tag）
    var package: String
    var title: String
    var text: String
    var ongoing: Bool          // 常駐通知（前景服務等）
    var firstSeen: Date
    var clearedAt: Date?
    var isActive: Bool { clearedAt == nil }
}

/// 一台裝置的所有已保存資料
struct PhoneDataBundle: Codable {
    var sms: [PhoneSMS] = []
    var calls: [PhoneCall] = []
    var notifications: [PhoneNotification] = []
    var lastSync: Date?
}

// MARK: - 解析 adb 輸出

enum PhoneDataParser {
    /// `content query` 的輸出：每筆以「Row: N 」開頭，欄位為 `key=value, key=value`；
    /// 值可能含逗號與換行，所以依投影欄位的固定順序切割（最後一欄可含任何內容）。
    static func rows(_ text: String, keys: [String]) -> [[String: String]] {
        var raws: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Row: "), let sp = line.dropFirst(5).firstIndex(of: " ") {
                raws.append(String(line[line.index(after: sp)...]))
            } else if !raws.isEmpty {
                raws[raws.count - 1] += "\n" + line
            }
        }
        return raws.compactMap { raw in
            var result: [String: String] = [:]
            var cursor = raw.startIndex
            var starts: [(String, String.Index, String.Index)] = []   // key, 標記起點, 值起點
            for (i, key) in keys.enumerated() {
                let needle = (i == 0 ? "" : ", ") + key + "="
                guard let r = raw.range(of: needle, range: cursor..<raw.endIndex) else { return nil }
                starts.append((key, r.lowerBound, r.upperBound))
                cursor = r.upperBound
            }
            for (i, s) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1].1 : raw.endIndex
                var v = String(raw[s.2..<end])
                if i + 1 == starts.count { v = v.trimmingCharacters(in: .newlines) }
                result[s.0] = v == "NULL" ? "" : v
            }
            return result
        }
    }

    static let smsKeys = ["_id", "address", "date", "type", "read", "body"]
    static let callKeys = ["_id", "number", "name", "date", "duration", "type"]

    static func sms(_ text: String) -> [PhoneSMS] {
        rows(text, keys: smsKeys).compactMap { r in
            guard let id = Int(r["_id"] ?? ""), let ms = Double(r["date"] ?? "") else { return nil }
            return PhoneSMS(id: id, address: r["address"] ?? "", date: Date(timeIntervalSince1970: ms / 1000),
                            type: Int(r["type"] ?? "") ?? 1, read: r["read"] == "1", body: r["body"] ?? "")
        }
    }

    static func calls(_ text: String) -> [PhoneCall] {
        rows(text, keys: callKeys).compactMap { r in
            guard let id = Int(r["_id"] ?? ""), let ms = Double(r["date"] ?? "") else { return nil }
            return PhoneCall(id: id, number: r["number"] ?? "", name: r["name"] ?? "",
                             date: Date(timeIntervalSince1970: ms / 1000),
                             duration: Int(r["duration"] ?? "") ?? 0, type: Int(r["type"] ?? "") ?? 0)
        }
    }

    struct ActiveNotification {
        var key: String
        var package: String
        var title: String
        var text: String
        var ongoing: Bool
    }

    /// `dumpsys notification --noredact` 的「Notification List」區段。
    /// 找不到這個區段（指令失敗）時回傳 nil，避免把所有通知誤判成已清除。
    static func notifications(_ dump: String) -> [ActiveNotification]? {
        var inList = false
        var found = false
        var out: [ActiveNotification] = []
        var cur: ActiveNotification?
        var title: String?, text: String?, bigText: String?

        func finish() {
            guard var c = cur else { return }
            c.title = title ?? ""
            c.text = (bigText?.isEmpty == false ? bigText : text) ?? ""
            out.append(c)
            cur = nil; title = nil; text = nil; bigText = nil
        }

        // 多行的 extras 值（文字含換行）：開頭有「(」但行尾沒有「)」，累積到出現行尾的「)」為止
        var open: (name: String, buf: String)?

        func assign(_ name: String, _ v: String) {
            switch name {
            case "title": title = v
            case "text": text = v
            default: bigText = v
            }
        }

        for sub in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            if !inList {
                if line.hasPrefix("  Notification List:") { inList = true; found = true }
                continue
            }
            if var o = open {
                o.buf += "\n" + line
                if line.hasSuffix(")") { assign(o.name, String(o.buf.dropLast())); open = nil } else { open = o }
                continue
            }
            // 區段結束：縮排剛好 2 格的下一個標題
            if line.hasPrefix("  "), line.dropFirst(2).first.map({ $0 != " " }) == true { finish(); break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("NotificationRecord(") {
                finish()
                guard let pkg = value(after: "pkg=", in: t), let key = value(after: "key=", in: t, until: ": Notification(") else { continue }
                let flags = value(after: "flags=0x", in: t).flatMap { Int($0, radix: 16) } ?? 0
                cur = ActiveNotification(key: key, package: pkg, title: "", text: "", ongoing: flags & 0x2 != 0)
            } else if cur != nil, t.hasPrefix("android.") {
                for (field, name) in [("android.title", "title"), ("android.text", "text"), ("android.bigText", "bigText")]
                where t.hasPrefix(field + "=") {
                    guard let paren = t.firstIndex(of: "("), t[t.startIndex..<paren].contains("String") else { break }
                    let rest = String(t[t.index(after: paren)...])
                    if t.hasSuffix(")") { assign(name, String(rest.dropLast())) } else { open = (name, rest) }
                    break
                }
            }
        }
        finish()
        return found ? out : nil
    }

    private static func value(after marker: String, in s: String, until end: String? = nil) -> String? {
        guard let r = s.range(of: marker) else { return nil }
        let rest = s[r.upperBound...]
        if let end, let e = rest.range(of: end) { return String(rest[..<e.lowerBound]) }
        return String(rest.prefix { $0 != " " })
    }
}
