import Foundation

/// 手機狀態：電池、網路（Wi-Fi 或行動網路世代）、主要 SIM 卡訊號格數
struct SimInfo: Equatable {
    var slot = 1
    var carrier = ""          // 目前收到的電信（基地台資訊裡已註冊的網路名稱），不是 SIM 卡本身的業者
    var tech = ""              // 例如「LTE」「5G」
    var dbm: Int?
    var bars = 0
    var inService = false
    var powerOff = false        // 無線電關閉（飛航模式等）
    var emergencyOnly = false   // 只能撥緊急電話（沒有正常服務）
}

struct DeviceStatus: Equatable {
    var batteryLevel = -1          // 0...100，-1 = 未知
    var charging = false
    var wifi = false
    /// 行動網路世代，例如「4G」「5G」；沒有行動資料連線時為 nil
    var cellularTech: String?
    var hasSim = false
    var signalBars = 0             // 0...4
    var inService = false
    var wifiLevel = 0              // 0...4
    var autoRotate = true
    var userRotation = 0           // 0...3，對應 0°／90°／180°／270°
    /// 強制所有 App 使用設定的方向（忽略 App 自己要求的方向）
    var forceOrientation = false

    // 以下給「總覽 → 裝置資訊」用
    /// 電池狀態碼（BatteryManager.BATTERY_STATUS_*）：2 充電中、3 放電中、4 插著但沒在充、5 已充飽；-1 未知
    var batteryStatus = -1
    var pluggedIn = false
    var carrier = ""
    /// 有插卡的每個卡槽（雙卡就兩筆）
    var sims: [SimInfo] = []
    var radioTech = ""             // 例如「LTE」「5G」
    var signalDbm: Int?
    var wifiSSID = ""
    var wifiIP = ""
    var batteryCycles: Int?
    var batteryMaxMah: Int?
    var batteryDesignMah: Int?
    var manufactureDate = ""       // yyyyMMdd（三星的 RF 校正日期，約等於出廠日）

    var summary: String {
        var parts: [String] = []
        if batteryLevel >= 0 { parts.append("電池 \(batteryLevel)%" + (charging ? "（充電中）" : "")) }
        if wifi { parts.append("Wi-Fi \(wifiLevel)/4") } else if let t = cellularTech { parts.append("行動網路 \(t)") } else { parts.append("沒有網路") }
        if hasSim { parts.append(inService ? "訊號 \(signalBars)/4" : "沒有服務") }
        return parts.joined(separator: " · ")
    }

    static let script = """
    echo '@@bat'; dumpsys battery | grep -E '^  (level|status|AC powered|USB powered|Wireless powered):'
    echo '@@net'; dumpsys connectivity | grep -E 'Active default network|NetworkAgentInfo\\{network\\{' | cut -c1-150
    echo '@@tel'; dumpsys telephony.registry | grep -E '^  Phone Id=|^    (mServiceState|mSignalStrength|mDataConnectionState|mCellInfo|mCellIdentity)=' | cut -c1-2000
    echo '@@sim'; getprop gsm.sim.state
    echo '@@wifi'; dumpsys wifi | grep -m1 -oE 'RSSI: -?[0-9]+'
    echo '@@wifiinfo'; dumpsys wifi | grep -m1 'mWifiInfo SSID' | cut -c1-200
    echo '@@ip'; ip -f inet addr show wlan0 2>/dev/null | grep -m1 inet
    echo '@@sys'; for f in cycle_count battery_cycle fg_cycle charge_full_design fg_fullcapnom charge_full; do echo "$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"; done
    echo '@@mfg'; getprop ril.rfcal_date
    echo '@@rot'; settings get system accelerometer_rotation; settings get system user_rotation
    echo '@@force'; wm get-ignore-orientation-request 2>/dev/null
    """

    static func fetch(_ c: AdbClient) async -> DeviceStatus? {
        guard let out = try? await c.shell(script, timeout: 10) else { return nil }
        return parse(out)
    }

    static func parse(_ text: String) -> DeviceStatus {
        var sections: [String: [String]] = [:]
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("@@") { current = String(line.dropFirst(2)); continue }
            sections[current, default: []].append(String(line))
        }
        var s = DeviceStatus()

        // 電池
        for l in sections["bat"] ?? [] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("level:") { s.batteryLevel = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? -1 }
            if t.hasPrefix("status:") { s.batteryStatus = Int(t.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? -1 }
            if t.hasSuffix("powered: true") { s.pluggedIn = true }
        }
        // 插著電不一定在充電（例如最佳化電池充電）：有狀態碼就只有「充電中」才算，沒有才退回看有沒有插電
        s.charging = s.batteryStatus >= 0 ? s.batteryStatus == 2 : s.pluggedIn

        // 目前預設網路：WIFI 或 MOBILE[LTE]
        let net = sections["net"] ?? []
        if let active = net.first(where: { $0.contains("Active default network") })?
            .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
           let agent = net.first(where: { $0.contains("network{\(active)}") }),
           let r = agent.range(of: "ni{") {
            let ni = agent[r.upperBound...].prefix { $0 != " " }
            if ni.hasPrefix("WIFI") { s.wifi = true }
            else if ni.hasPrefix("MOBILE") {
                let rat = ni.drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
                s.cellularTech = generation(String(rat))
            }
        }

        if s.wifi, let r = (sections["wifi"] ?? []).first(where: { $0.hasPrefix("RSSI:") }), let rssi = Int(r.replacingOccurrences(of: "RSSI:", with: "").trimmingCharacters(in: .whitespaces)) {
            // 同 Android 的 calculateSignalLevel：-100…-55 dBm 對應 0…4 格
            s.wifiLevel = max(0, min(4, (rssi + 100) * 4 / 45))
        } else if s.wifi { s.wifiLevel = 4 }
        // Wi-Fi 名稱與 IP
        // grep 提早結束時 dumpsys 會多印一行「Failed to write … Broken pipe」，所以要找含 SSID 的那一行，不能直接取第一行
        if let info = sections["wifiinfo"]?.first(where: { $0.contains("SSID: \"") }), let r = info.range(of: "SSID: \"") {
            s.wifiSSID = String(info[r.upperBound...].prefix { $0 != "\"" })
        }
        if let l = sections["ip"]?.first(where: { $0.contains("inet ") }), let r = l.range(of: "inet ") {
            s.wifiIP = String(l[r.upperBound...].prefix { $0 != "/" && $0 != " " })
        }
        // 電池循環次數與容量（sysfs；各家欄位不同）
        var sys: [String: Int] = [:]
        for l in sections["sys"] ?? [] {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let v = Int(kv[1].trimmingCharacters(in: .whitespaces)) { sys[kv[0]] = v }
        }
        s.batteryCycles = ["cycle_count", "battery_cycle", "fg_cycle"].compactMap { sys[$0] }.first { $0 > 0 }
        func mah(_ v: Int?) -> Int? { v.flatMap { $0 > 0 ? ($0 > 100_000 ? $0 / 1000 : $0) : nil } }
        s.batteryDesignMah = mah(sys["charge_full_design"])
        s.batteryMaxMah = mah(sys["fg_fullcapnom"]) ?? mah(sys["charge_full"])
        s.manufactureDate = (sections["mfg"]?.first ?? "").trimmingCharacters(in: .whitespaces)
        s.forceOrientation = (sections["force"] ?? []).contains { $0.contains("true") }
        let rot = sections["rot"] ?? []
        if rot.count >= 1 { s.autoRotate = rot[0].trimmingCharacters(in: .whitespaces) != "0" }
        if rot.count >= 2 { s.userRotation = Int(rot[1].trimmingCharacters(in: .whitespaces)) ?? 0 }

        // SIM 與訊號：有資料連線的那張算主要 SIM，否則取第一張
        let simStates = (sections["sim"]?.first ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        s.hasSim = simStates.contains { $0 != "ABSENT" && !$0.isEmpty && $0 != "UNKNOWN" }
        var phones: [[String]] = []
        for l in sections["tel"] ?? [] {
            if l.hasPrefix("  Phone Id=") { phones.append([]) }
            else if !phones.isEmpty { phones[phones.count - 1].append(l) }
        }
        let parsed = phones.map(parsePhone)
        // 每個有插卡的卡槽各一筆（雙卡時「總覽」會分開列出）
        s.sims = parsed.enumerated().compactMap { i, p in
            var p = p
            p.slot = i + 1
            if simStates.count == parsed.count, ["ABSENT", "UNKNOWN", ""].contains(simStates[i]) { return nil }
            return p
        }
        let primaryIndex = phones.firstIndex { $0.contains { $0.contains("mDataConnectionState=2") } } ?? (phones.isEmpty ? nil : 0)
        if let i = primaryIndex {
            let p = parsed[i]
            s.inService = p.inService
            s.radioTech = p.tech
            s.carrier = p.carrier
            s.signalDbm = p.dbm
            s.signalBars = p.bars
        }
        return s
    }

    /// 解析一個卡槽（telephony.registry 的一個 Phone Id 區塊）
    private static func parsePhone(_ lines: [String]) -> SimInfo {
        var p = SimInfo()
        if let svc = lines.first(where: { $0.contains("mServiceState=") }) {
            p.inService = svc.contains("mVoiceRegState=0") || svc.contains("mDataRegState=0")
            p.emergencyOnly = svc.contains("mIsEmergencyOnly=true")
            p.powerOff = svc.contains("mVoiceRegState=3")
            // 「getRilDataRadioTechnology=14(LTE)」→ LTE；NR 顯示 5G
            for key in ["getRilDataRadioTechnology=", "getRilVoiceRadioTechnology="] {
                guard let r = svc.range(of: key), let o = svc[r.upperBound...].firstIndex(of: "(") else { continue }
                let name = String(svc[svc.index(after: o)...].prefix { $0 != ")" })
                if !name.isEmpty, name != "Unknown" { p.tech = name.hasPrefix("NR") ? "5G" : name; break }
            }
        }
        // 已註冊的基地台可能不只一個，其中有的是無效資料（例如三星雙卡時的 WCDMA「mMcc=000 mAlphaLong=000000」），
        // 名稱是空的或全是數字就跳過；都沒有就退回目前服務基地台（mCellIdentity）的名稱
        func alpha(in s: Substring) -> String? {
            guard let a = s.range(of: "mAlphaLong=") else { return nil }
            let name = String(s[a.upperBound...].prefix { $0 != " " && $0 != "}" })
            return name.isEmpty || name.allSatisfy(\.isNumber) ? nil : name
        }
        if let cell = lines.first(where: { $0.contains("mCellInfo=") }) {
            var rest = cell[...]
            while p.carrier.isEmpty, let reg = rest.range(of: "mRegistered=YES") {
                rest = rest[reg.upperBound...]
                let end = rest.range(of: "mRegistered=")?.lowerBound ?? rest.endIndex
                if let name = alpha(in: rest[..<end]) { p.carrier = name }
            }
        }
        if p.carrier.isEmpty, let id = lines.first(where: { $0.contains("mCellIdentity=") }), let name = alpha(in: id[...]) {
            p.carrier = name
        }
        if let sig = lines.first(where: { $0.contains("mSignalStrength=") }) {
            for key in ["rsrp=", "ssRsrp=", "rssi="] {
                if let r = sig.range(of: key) {
                    let n = Int(sig[r.upperBound...].prefix { $0 == "-" || $0.isNumber }) ?? 0
                    if n < 0, n > -200 { p.dbm = n; break }
                }
            }
            // 三星的狀態列用 SignalBarInfo 的格數（例如 lteLevel=4），沒有才用標準的 level=
            if let r = sig.range(of: "SignalBarInfo{"), let l = sig[r.upperBound...].range(of: "Level=") {
                p.bars = min(4, Int(sig[l.upperBound...].prefix { $0.isNumber }) ?? 0)
            } else if let r = sig.range(of: "level=") {
                p.bars = min(4, Int(sig[r.upperBound...].prefix { $0.isNumber }) ?? 0)
            }
        }
        return p
    }

    private static func generation(_ rat: String) -> String {
        switch rat.uppercased() {
        case "NR", "NR_NSA": return "5G"
        case "LTE", "LTE_CA", "IWLAN": return "4G"
        case "HSPAP", "HSPA", "HSDPA", "HSUPA", "UMTS", "TD_SCDMA": return "3G"
        case "EDGE", "GPRS", "GSM": return "2G"
        case "": return "4G"
        default: return rat
        }
    }
}
