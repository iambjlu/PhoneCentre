import Foundation
import Network

/// 分享伺服器：開一個加密的 port，讓其他 PhoneCentre 使用這台 Mac 上的 adb server（本機 5037）
@MainActor
final class ShareServer: ObservableObject {
    static let shared = ShareServer()

    @Published private(set) var status = "未啟動"
    @Published private(set) var activeConnections = 0
    private var listener: NWListener?
    private var failures: [String: (count: Int, until: Date)] = [:]
    private let queue = DispatchQueue(label: "PhoneCentre.share")

    func apply() {
        let s = AppSettings.shared
        stop()
        guard s.remoteEnabled else { status = "遠端功能已關閉"; return }
        guard s.shareEnabled else { status = "未啟動"; return }
        let pw = s.sharePassword
        guard pw.count >= 6 else { status = "請設定至少 6 個字元的密碼"; return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: s.sharePort)) else { status = "Port 無效"; return }
        status = "啟動中…"
        Task.detached { [weak self] in
            let params = SecureChannel.parameters(password: pw)   // PBKDF2 較慢，放背景
            await self?.startListener(params, port: port)
        }
    }

    private func startListener(_ params: NWParameters, port: NWEndpoint.Port) {
        do {
            let l = try NWListener(using: params, on: port)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "PhoneCentre", type: SecureChannel.serviceType)
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: self?.status = "執行中（port \(port.rawValue)）"
                    case .failed(let e): self?.status = "失敗：\(e.localizedDescription)"
                    case .cancelled: self?.status = "未啟動"
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in self?.accept(c) }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            status = "無法開啟 port：\(error.localizedDescription)"
        }
    }

    private func accept(_ c: NWConnection) {
        let ip: String
        if case let .hostPort(host, _) = c.endpoint { ip = "\(host)" } else { ip = "?" }
        // 握手一直失敗的來源暫時封鎖
        if let f = failures[ip], f.until > Date() { c.cancel(); return }

        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready:
                    self.failures[ip] = nil
                    self.bridge(c)
                case .failed:
                    var f = self.failures[ip] ?? (0, .distantPast)
                    f.count += 1
                    if f.count >= 5 { f.until = Date().addingTimeInterval(60 * Double(f.count - 4)) }
                    self.failures[ip] = f
                    c.cancel()
                default: break
                }
            }
        }
        c.start(queue: queue)
    }

    /// 已通過 PSK 驗證：接到本機 adb server
    private func bridge(_ c: NWConnection) {
        let adb = NWConnection(host: "127.0.0.1", port: 5037, using: .tcp)
        activeConnections += 1
        adb.start(queue: queue)
        SecureChannel.pipe(c, adb) { [weak self] in
            Task { @MainActor in self?.activeConnections -= 1 }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// 連到其他 PhoneCentre：在本機開一個 port（僅 127.0.0.1），把連線加密轉送到遠端，對本機程式來說就像另一個 adb server
@MainActor
final class RemoteManager: ObservableObject {
    static let shared = RemoteManager()

    struct Tunnel {
        var listener: NWListener
        var port: UInt16
        var host: RemoteHost
        var ok = false
    }

    @Published private(set) var status: [UUID: String] = [:]
    private var tunnels: [UUID: Tunnel] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "PhoneCentre.remote")

    /// 已通過驗證、可以查詢裝置的遠端 adb 端點
    var connectedEndpoints: [AdbEndpoint] {
        tunnels.values.filter(\.ok).map { AdbEndpoint(host: "127.0.0.1", port: Int($0.port), remoteID: $0.host.id) }
    }

    func start() {
        apply()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.healthCheck() }
        }
    }

    /// 設定變動後同步通道
    func apply() {
        // 遠端功能關閉時等於沒有任何主機：現有通道全部關掉
        let hosts = AppSettings.shared.remoteEnabled ? AppSettings.shared.remoteHosts : []
        for (id, t) in tunnels where !hosts.contains(where: { $0.id == id && $0.autoConnect && $0 == t.host }) {
            t.listener.cancel()
            tunnels[id] = nil
            status[id] = nil
        }
        for h in hosts where h.autoConnect && tunnels[h.id] == nil {
            open(h)
        }
    }

    func reconnect(_ h: RemoteHost) {
        guard AppSettings.shared.remoteEnabled else { return }
        tunnels[h.id]?.listener.cancel()
        tunnels[h.id] = nil
        open(h)
    }

    private func open(_ h: RemoteHost) {
        let pw = AppSettings.shared.secret(h.secretKey) ?? ""
        guard !pw.isEmpty else { status[h.id] = "尚未設定密碼"; return }
        status[h.id] = "連線中…"
        Task.detached { [weak self] in
            let params = SecureChannel.parameters(password: pw)
            await self?.openListener(h, params)
        }
    }

    private func openListener(_ h: RemoteHost, _ remoteParams: NWParameters) {
        let local = NWParameters.tcp
        local.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: local) else { status[h.id] = "無法開啟本機 port"; return }
        let queue = queue
        l.newConnectionHandler = { inbound in
            let remote = NWConnection(host: NWEndpoint.Host(h.host), port: NWEndpoint.Port(rawValue: UInt16(h.port))!, using: remoteParams)
            inbound.start(queue: queue)
            remote.start(queue: queue)
            SecureChannel.pipe(inbound, remote)
        }
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = st, let p = l.port?.rawValue {
                    self.tunnels[h.id] = Tunnel(listener: l, port: p, host: h)
                    await self.healthCheck()
                }
                if case .failed(let e) = st { self.status[h.id] = "失敗：\(e.localizedDescription)" }
            }
        }
        l.start(queue: queue)
    }

    /// 透過通道問遠端 adb server 版本，確認密碼正確且對方在線
    private func healthCheck() async {
        for (id, t) in tunnels {
            let ep = AdbEndpoint(host: "127.0.0.1", port: Int(t.port), remoteID: id)
            let ok = (try? await Task.detached { try AdbSocket.hostQuery(ep, "host:version") }.value) != nil
            tunnels[id]?.ok = ok
            status[id] = ok ? "已連線" : "無法連線（對方未開啟分享、網路不通或密碼錯誤）"
        }
    }
}
