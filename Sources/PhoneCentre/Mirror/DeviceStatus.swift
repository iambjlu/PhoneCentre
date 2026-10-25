import Foundation

/// 手機狀態：電池、網路（Wi-Fi 或行動網路世代）、主要 SIM 卡訊號格數
struct DeviceStatus: Equatable {
    var batteryLevel = -1          // 0...100，-1 = 未知
    var charging = false
    var wifi = false
    /// 行動網路世代，例如「4G」「5G」；沒有行動資料連線時為 nil
    var cellularTech: String?
    var hasSim = false
    var signalBars = 0             // 0...4
    var inService = false

    var summary: String {
        var parts: [String] = []
        if batteryLevel >= 0 { parts.append("電池 \(batteryLevel)%" + (charging ? "（充電中）" : "")) }
        if wifi { parts.append("Wi-Fi") } else if let t = cellularTech { parts.append("行動網路 \(t)") } else { parts.append("沒有網路") }
        if hasSim { parts.append(inService ? "訊號 \(signalBars)/4" : "沒有服務") }
        return parts.joined(separator: " · ")
    }

    static let script = """
    echo '@@bat'; dumpsys battery | grep -E '^  (level|AC powered|USB powered|Wireless powered):'
    echo '@@net'; dumpsys connectivity | grep -E 'Active default network|NetworkAgentInfo\\{network\\{' | cut -c1-150
    echo '@@tel'; dumpsys telephony.registry | grep -E '^  Phone Id=|^    (mServiceState|mSignalStrength|mDataConnectionState)=' | cut -c1-420
    echo '@@sim'; getprop gsm.sim.state
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
            if t.hasSuffix("powered: true") { s.charging = true }
        }

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

        // SIM 與訊號：有資料連線的那張算主要 SIM，否則取第一張
        let simStates = (sections["sim"]?.first ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        s.hasSim = simStates.contains { $0 != "ABSENT" && !$0.isEmpty && $0 != "UNKNOWN" }
        var phones: [[String]] = []
        for l in sections["tel"] ?? [] {
            if l.hasPrefix("  Phone Id=") { phones.append([]) }
            else if !phones.isEmpty { phones[phones.count - 1].append(l) }
        }
        let primary = phones.first { $0.contains { $0.contains("mDataConnectionState=2") } } ?? phones.first
        if let primary {
            if let svc = primary.first(where: { $0.contains("mServiceState=") }) {
                s.inService = svc.contains("mVoiceRegState=0") || svc.contains("mDataRegState=0")
                if s.cellularTech == nil, s.wifi == false { /* 沒有網路 */ }
            }
            if let sig = primary.first(where: { $0.contains("mSignalStrength=") }),
               let r = sig.range(of: "level=") {
                s.signalBars = min(4, Int(sig[r.upperBound...].prefix { $0.isNumber }) ?? 0)
            }
        }
        if !s.inService { s.signalBars = 0 }
        return s
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
