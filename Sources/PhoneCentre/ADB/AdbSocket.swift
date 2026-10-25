import Foundation
import Darwin

/// adb server 的位置。本機為 127.0.0.1:5037；遠端 PhoneCentre 透過加密通道映射到本機的另一個 port。
struct AdbEndpoint: Hashable, Codable {
    var host: String = "127.0.0.1"
    var port: Int = 5037
    /// 遠端主機的 ID（本機為 nil）
    var remoteID: UUID?
    static let local = AdbEndpoint()
    var isLocal: Bool { remoteID == nil }
}

enum AdbError: LocalizedError {
    case connectFailed(String)
    case protocolError(String)
    case failed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .connectFailed(let s): return "無法連線到 adb server：\(s)"
        case .protocolError(let s): return "adb 協定錯誤：\(s)"
        case .failed(let s): return s
        case .closed: return "連線已關閉"
        }
    }
}

/// 直接走 adb server 協定的 socket（阻塞式，請在背景執行緒使用）
final class AdbSocket {
    private(set) var fd: Int32 = -1
    private let lock = NSLock()

    init(endpoint: AdbEndpoint, timeout: TimeInterval = 5) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(endpoint.host, String(endpoint.port), &hints, &res) == 0, let info = res else {
            throw AdbError.connectFailed("無法解析 \(endpoint.host)")
        }
        defer { freeaddrinfo(res) }
        fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw AdbError.connectFailed("socket()") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(timeout)
        if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd); fd = -1
            throw AdbError.connectFailed(msg)
        }
    }

    deinit { close() }

    /// timeout 為 0 代表不限制
    func setTimeout(_ t: TimeInterval) {
        var tv = timeval(tv_sec: Int(t), tv_usec: Int32((t - floor(t)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: 讀寫

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = Darwin.send(fd, p.baseAddress! + off, p.count - off, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw AdbError.closed
                }
                off += n
            }
        }
    }

    func readExact(_ count: Int) throws -> Data {
        var buf = Data(count: count)
        var off = 0
        try buf.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            while off < count {
                let n = Darwin.recv(fd, p.baseAddress! + off, count - off, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw AdbError.closed
                }
                off += n
            }
        }
        return buf
    }

    func readSome(max: Int = 65_536) throws -> Data {
        var buf = Data(count: max)
        let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, max, 0) }
        if n <= 0 { throw AdbError.closed }
        return buf.prefix(n)
    }

    func readToEnd() -> Data {
        var all = Data()
        while let d = try? readSome() { all.append(d) }
        return all
    }

    // MARK: adb server 協定

    func sendRequest(_ s: String) throws {
        let payload = Data(s.utf8)
        try write(Data(String(format: "%04x", payload.count).utf8) + payload)
        let status = String(decoding: try readExact(4), as: UTF8.self)
        if status == "OKAY" { return }
        if status == "FAIL" {
            throw AdbError.failed(try readLengthPrefixedString())
        }
        throw AdbError.protocolError("未預期的回應 \(status)")
    }

    func readLengthPrefixedString() throws -> String {
        let lenHex = String(decoding: try readExact(4), as: UTF8.self)
        guard let len = Int(lenHex, radix: 16) else { throw AdbError.protocolError("長度 \(lenHex)") }
        return String(decoding: try readExact(len), as: UTF8.self)
    }

    // MARK: 便利方法

    /// host: 開頭的查詢，例如 host:devices-l、host:version
    static func hostQuery(_ endpoint: AdbEndpoint, _ request: String) throws -> String {
        let s = try AdbSocket(endpoint: endpoint, timeout: 3)
        defer { s.close() }
        try s.sendRequest(request)
        return try s.readLengthPrefixedString()
    }

    /// 開啟到裝置上某個服務的串流，例如 localabstract:scrcpy_xxx、shell:xxx
    static func open(_ endpoint: AdbEndpoint, serial: String, service: String, timeout: TimeInterval = 5) throws -> AdbSocket {
        let s = try AdbSocket(endpoint: endpoint, timeout: timeout)
        do {
            try s.sendRequest("host:transport:\(serial)")
            try s.sendRequest(service)
        } catch {
            s.close()
            throw error
        }
        s.setTimeout(0)
        return s
    }
}
