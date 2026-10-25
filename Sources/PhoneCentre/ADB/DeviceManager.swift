import Foundation
import Combine

enum AdbServerStatus: Equatable {
    case unknown
    case missingAdb          // 系統上找不到 adb
    case running
    case down(String)        // server 沒在跑（可能被其他程式砍掉）
}

/// 管理所有裝置清單、自動維持 adb server 與無線裝置重連
@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var serverStatus: AdbServerStatus = .unknown
    @Published private(set) var lastEvent: String = ""
    /// 正在重連的無線位址
    @Published private(set) var reconnecting: Set<String> = []

    private var infoCache: [String: DeviceInfo] = [:]
    private var infoLoading: Set<String> = []
    private var catalogs: [String: AppCatalog] = [:]
    private var timer: Timer?
    private var refreshing = false
    private var lastServerStart = Date.distantPast
    private var backoff: [String: (next: Date, delay: TimeInterval)] = [:]
    private let settings = AppSettings.shared

    var onlineDevices: [Device] { devices.filter(\.isOnline) }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func device(id: String) -> Device? { devices.first { $0.id == id } }

    func catalog(for device: Device) -> AppCatalog {
        if let c = catalogs[device.id] { c.device = device; return c }
        let c = AppCatalog(device: device)
        catalogs[device.id] = c
        return c
    }

    // MARK: 輪詢

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        guard AdbLocator.find() != nil else {
            serverStatus = .missingAdb
            devices = devices.filter(\.isRemote)
            return
        }

        var all: [Device] = []

        // 本機 adb server
        do {
            let text = try await Task.detached { try AdbSocket.hostQuery(.local, "host:devices-l") }.value
            if serverStatus != .running, case .down = serverStatus { log("adb server 已恢復") }
            serverStatus = .running
            all += Device.parse(text, endpoint: .local)
        } catch {
            serverStatus = .down(error.localizedDescription)
            if settings.keepAlive, Date().timeIntervalSince(lastServerStart) > 4 {
                lastServerStart = Date()
                log("adb server 不在執行，正在重新啟動…")
                await AdbClient.startServer()
                // server 重啟後，所有無線連線都會消失，立刻重連
                backoff.removeAll()
            }
        }

        // 遠端 PhoneCentre
        for ep in RemoteManager.shared.connectedEndpoints {
            if let text = try? await Task.detached(operation: { try AdbSocket.hostQuery(ep, "host:devices-l") }).value {
                all += Device.parse(text, endpoint: ep)
            }
        }

        for i in all.indices { all[i].info = infoCache[all[i].id] }
        if all != devices {
            devices = all
            CacheManager.shared.devicesChanged(all)
        }

        for d in all where d.isOnline && infoCache[d.id] == nil && !infoLoading.contains(d.id) {
            loadInfo(d)
        }

        if serverStatus == .running { await maintainWireless(online: all) }
    }

    private func loadInfo(_ d: Device) {
        infoLoading.insert(d.id)
        Task {
            let info = await DeviceInfo.fetch(d.client)
            infoLoading.remove(d.id)
            guard let info else { return }
            infoCache[d.id] = info
            if let i = devices.firstIndex(where: { $0.id == d.id }) { devices[i].info = info }
            if d.isWireless, !d.isRemote, settings.rememberWireless { remember(d.serial, info: info) }
        }
    }

    // MARK: 無線裝置

    private func remember(_ address: String, info: DeviceInfo?) {
        guard address.contains(":"), !address.contains("._adb-tls") else { return }
        var list = settings.savedEndpoints
        if let i = list.firstIndex(where: { $0.address == address }) {
            if let info { list[i].serialNo = info.serialNo; list[i].name = info.deviceName.isEmpty ? info.model : info.deviceName }
        } else {
            // 同一台手機換了 port，就更新舊紀錄
            if let info, let i = list.firstIndex(where: { $0.serialNo == info.serialNo }) { list.remove(at: i) }
            list.append(SavedEndpoint(address: address, serialNo: info?.serialNo,
                                      name: info.map { $0.deviceName.isEmpty ? $0.model : $0.deviceName }))
        }
        if list != settings.savedEndpoints { settings.savedEndpoints = list }
    }

    func forget(_ ep: SavedEndpoint) {
        settings.savedEndpoints.removeAll { $0.address == ep.address }
        Task { await AdbClient.disconnect(ep.address) }
    }

    private func maintainWireless(online: [Device]) async {
        guard settings.keepAlive else { return }
        let localOnline = Set(online.filter { !$0.isRemote && $0.isOnline }.map(\.serial))
        let onlineSerialNos = Set(online.compactMap { $0.isOnline ? $0.info?.serialNo : nil })
        for ep in settings.savedEndpoints {
            if localOnline.contains(ep.address) { backoff[ep.address] = nil; continue }
            // 同一台手機已經用別的方式（USB、新 port）連上了，就不重連
            if let sn = ep.serialNo, onlineSerialNos.contains(sn) { continue }
            if let b = backoff[ep.address], b.next > Date() { continue }
            Task { await reconnect(ep) }
            let delay = min((backoff[ep.address]?.delay ?? 2.5) * 2, 60)
            backoff[ep.address] = (Date().addingTimeInterval(delay), delay)
        }
    }

    private func reconnect(_ ep: SavedEndpoint) async {
        guard !reconnecting.contains(ep.address) else { return }
        reconnecting.insert(ep.address)
        defer { reconnecting.remove(ep.address) }

        // 若裝置還在清單中但離線，先斷開再連
        if devices.contains(where: { $0.serial == ep.address && !$0.isOnline }) {
            await AdbClient.disconnect(ep.address)
        }
        let r = await AdbClient.connect(ep.address)
        if r.ok {
            log("已重新連線 \(ep.name ?? ep.address)")
            backoff[ep.address] = nil
            return
        }
        // 無線偵錯的 port 可能變了：用 mDNS 找同一台手機
        if let sn = ep.serialNo, !sn.isEmpty {
            for svc in await AdbClient.mdnsServices() where svc.type.contains("connect") && svc.instance.contains(sn) {
                let r2 = await AdbClient.connect(svc.address)
                if r2.ok {
                    log("\(ep.name ?? sn) 的 port 已變更為 \(svc.address)，已重新連線")
                    var list = settings.savedEndpoints
                    list.removeAll { $0.address == ep.address }
                    list.append(SavedEndpoint(address: svc.address, serialNo: sn, name: ep.name))
                    settings.savedEndpoints = list
                    return
                }
            }
        }
    }

    // MARK: 使用者動作

    func connect(_ address: String) async -> (Bool, String) {
        var addr = address.trimmingCharacters(in: .whitespaces)
        if !addr.contains(":") { addr += ":5555" }
        let r = await AdbClient.connect(addr)
        if r.ok, settings.rememberWireless { remember(addr, info: nil) }
        await refresh()
        return (r.ok, r.message)
    }

    /// USB 裝置轉無線：`adb tcpip 5555`，取得手機 Wi-Fi IP 後 `adb connect`
    func enableWireless(_ device: Device) async -> (Bool, String) {
        let c = device.client
        let out = (try? await c.shell("ip -f inet addr show wlan0 | grep -o 'inet [0-9.]*' | head -1")) ?? ""
        guard let ip = out.split(separator: " ").last.map(String.init), !ip.isEmpty else {
            return (false, "取不到手機的 Wi-Fi IP，請確認手機已連上 Wi-Fi")
        }
        guard let r = try? await c.cli(["tcpip", "5555"]), r.status == 0 else {
            return (false, "adb tcpip 5555 失敗")
        }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        let result = await connect("\(ip):5555")
        return result.0 ? (true, "已切換為無線：\(ip):5555，現在可以拔掉 USB") : result
    }

    func disconnect(_ device: Device) async {
        settings.savedEndpoints.removeAll { $0.address == device.serial }
        await AdbClient.disconnect(device.serial, endpoint: device.endpoint)
        await refresh()
    }

    func log(_ s: String) {
        lastEvent = s
        NSLog("[PhoneCentre] %@", s)
    }
}
