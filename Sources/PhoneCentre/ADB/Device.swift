import Foundation

/// adb 回報的一台裝置
struct Device: Identifiable, Hashable {
    var serial: String
    var state: String
    var model: String = ""
    var product: String = ""
    var transportId: String = ""
    var endpoint: AdbEndpoint = .local
    var info: DeviceInfo?

    /// 本機：serial；遠端：<remoteID>|serial
    var id: String { Device.makeID(serial: serial, endpoint: endpoint) }

    static func makeID(serial: String, endpoint: AdbEndpoint) -> String {
        endpoint.remoteID.map { "\($0.uuidString)|\(serial)" } ?? serial
    }

    var isOnline: Bool { state == "device" }
    var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-connect") }
    var isRemote: Bool { !endpoint.isLocal }
    var client: AdbClient { AdbClient(endpoint: endpoint, serial: serial) }

    var displayName: String {
        if let n = info?.deviceName, !n.isEmpty { return n }
        if !model.isEmpty { return model.replacingOccurrences(of: "_", with: " ") }
        return serial
    }

    var subtitle: String {
        var parts: [String] = []
        if let m = info?.manufacturer, !m.isEmpty { parts.append(m.uppercased() + " " + (info?.model ?? model)) }
        else if !model.isEmpty { parts.append(model) }
        if let v = info?.androidVersion { parts.append("Android \(v)") }
        return parts.joined(separator: " · ")
    }

    var stateDescription: String {
        switch state {
        case "device": return "已連線"
        case "offline": return "離線"
        case "unauthorized": return "未授權（請在手機上允許 USB 偵錯）"
        case "authorizing": return "授權中"
        default: return state
        }
    }

    var symbolName: String {
        if isRemote { return "network" }
        return isWireless ? "wifi" : "cable.connector"
    }

    /// 解析 host:devices-l
    static func parse(_ text: String, endpoint: AdbEndpoint) -> [Device] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            var d = Device(serial: parts[0], state: parts[1], endpoint: endpoint)
            for p in parts.dropFirst(2) {
                let kv = p.split(separator: ":", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "model": d.model = kv[1]
                case "product": d.product = kv[1]
                case "transport_id": d.transportId = kv[1]
                default: break
                }
            }
            return d
        }
    }
}

/// 連線後一次性抓取的裝置資訊
struct DeviceInfo: Hashable {
    var deviceName: String
    var manufacturer: String
    var model: String
    var androidVersion: String
    var sdk: Int
    var serialNo: String
    var screenSize: String
    var density: Int

    static func fetch(_ c: AdbClient) async -> DeviceInfo? {
        let script = """
        echo "$(settings get global device_name)"; getprop ro.product.manufacturer; getprop ro.product.model; \
        getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.serialno; wm size | tail -1; \
        wm density | tail -1
        """
        guard let out = try? await c.shell(script) else { return nil }
        let l = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard l.count >= 6 else { return nil }
        let name = l[0] == "null" ? "" : l[0]
        return DeviceInfo(deviceName: name, manufacturer: l[1], model: l[2], androidVersion: l[3],
                          sdk: Int(l[4]) ?? 0, serialNo: l[5],
                          screenSize: l.count > 6 ? afterColon(l[6]) : "",
                          density: l.count > 7 ? Int(afterColon(l[7])) ?? 420 : 420)
    }

    /// 「Physical size: 1080x2280」→「1080x2280」
    private static func afterColon(_ s: String) -> String {
        (s.split(separator: ":").last.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
    }
}
