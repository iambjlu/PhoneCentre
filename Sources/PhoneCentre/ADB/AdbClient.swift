import Foundation

/// adb 操作：短指令走 socket（快、不用開程序），檔案傳輸與 server 管理走 adb CLI
struct AdbClient {
    var endpoint: AdbEndpoint
    var serial: String

    static var adbPath: String? { AdbLocator.find() }

    // MARK: Shell

    /// 在裝置上執行指令並取回輸出（exec: 服務，無 pty，二進位安全）
    func exec(_ command: String, timeout: TimeInterval = 15) async throws -> Data {
        let ep = endpoint, serial = serial
        return try await Task.detached {
            let s = try AdbSocket.open(ep, serial: serial, service: "exec:\(command)")
            s.setTimeout(timeout)
            defer { s.close() }
            return s.readToEnd()
        }.value
    }

    func shell(_ command: String, timeout: TimeInterval = 15) async throws -> String {
        String(decoding: try await exec(command, timeout: timeout), as: UTF8.self)
    }

    func getprop(_ key: String) async -> String {
        ((try? await shell("getprop \(key)")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: CLI

    private var baseArgs: [String] {
        var a: [String] = []
        if endpoint != .local { a += ["-H", endpoint.host, "-P", String(endpoint.port)] }
        a += ["-s", serial]
        return a
    }

    func cli(_ args: [String], timeout: TimeInterval? = nil) async throws -> ShellResult {
        guard let adb = Self.adbPath else { throw AdbError.failed("找不到 adb") }
        return try await Shell.run(adb, baseArgs + args, timeout: timeout)
    }

    func push(_ local: URL, to remote: String) async throws {
        let r = try await cli(["push", local.path, remote])
        if r.status != 0 { throw AdbError.failed(r.stderr.isEmpty ? r.text : r.stderr) }
        // 讓媒體庫看到新檔案
        _ = try? await shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(Shell.quote("file://" + remote)) >/dev/null 2>&1")
    }

    func pull(_ remote: String, to local: URL) async throws {
        let r = try await cli(["pull", "-a", remote, local.path])
        if r.status != 0 { throw AdbError.failed(r.stderr.isEmpty ? r.text : r.stderr) }
    }

    func install(_ apk: URL) async throws {
        let r = try await cli(["install", "-r", "-d", apk.path])
        if r.status != 0 || r.text.contains("Failure") {
            throw AdbError.failed((r.text + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Server 層級

    static func serverCLI(_ endpoint: AdbEndpoint, _ args: [String], timeout: TimeInterval = 15) async throws -> ShellResult {
        guard let adb = adbPath else { throw AdbError.failed("找不到 adb") }
        var a: [String] = []
        if endpoint != .local { a += ["-H", endpoint.host, "-P", String(endpoint.port)] }
        return try await Shell.run(adb, a + args, timeout: timeout)
    }

    static func startServer() async {
        _ = try? await serverCLI(.local, ["start-server"], timeout: 15)
    }

    /// adb connect；回傳 adb 的訊息
    @discardableResult
    static func connect(_ address: String, endpoint: AdbEndpoint = .local) async -> (ok: Bool, message: String) {
        let ep = endpoint
        let msg: String
        do {
            msg = try await Task.detached { try AdbSocket.hostQuery(ep, "host:connect:\(address)") }.value
        } catch {
            return (false, error.localizedDescription)
        }
        let ok = msg.contains("connected to") && !msg.contains("failed") && !msg.contains("unable")
        return (ok, msg)
    }

    static func disconnect(_ address: String, endpoint: AdbEndpoint = .local) async {
        let ep = endpoint
        _ = try? await Task.detached { try AdbSocket.hostQuery(ep, "host:disconnect:\(address)") }.value
    }

    static func pair(_ address: String, code: String) async -> (ok: Bool, message: String) {
        do {
            let r = try await serverCLI(.local, ["pair", address, code], timeout: 30)
            let msg = (r.text + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (msg.contains("Successfully paired"), msg)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// adb mdns services → [(instance, type, address)]
    static func mdnsServices() async -> [(instance: String, type: String, address: String)] {
        guard let r = try? await serverCLI(.local, ["mdns", "services"], timeout: 5) else { return [] }
        return r.text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
            guard parts.count >= 3, parts[1].hasPrefix("_adb") else { return nil }
            return (parts[0], parts[1], parts[2])
        }
    }
}
