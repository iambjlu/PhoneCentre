import CommonCrypto
import CryptoKit
import Foundation
import Network

/// PhoneCentre 之間的加密通道：TLS（PSK），PSK 由密碼經 PBKDF2 推導，雙方密碼相同才能完成握手
enum SecureChannel {
    static let serviceType = "_phonecentre._tcp"
    private static let identity = "PhoneCentre-v1"

    /// PBKDF2-SHA256，20 萬次，提高離線暴力破解成本
    static func derive(_ password: String) -> Data {
        let salt = Data("PhoneCentre/adb-share/psk".utf8)
        var out = Data(count: 32)
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        _ = out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                     o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    private static var keyCache: [String: Data] = [:]
    private static let cacheLock = NSLock()

    static func parameters(password: String) -> NWParameters {
        cacheLock.lock()
        let key: Data
        if let k = keyCache[password] { key = k } else { key = derive(password); keyCache[password] = key }
        cacheLock.unlock()

        let tls = NWProtocolTLS.Options()
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let ident = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, ident as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    /// 雙向轉送兩條連線
    static func pipe(_ a: NWConnection, _ b: NWConnection, onClose: @escaping () -> Void = {}) {
        let closed = ManagedAtomicFlag()
        func close() {
            guard closed.setOnce() else { return }
            a.cancel(); b.cancel()
            onClose()
        }
        func forward(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, err in
                if let data, !data.isEmpty {
                    to.send(content: data, completion: .contentProcessed { e in
                        if e != nil || done || err != nil { close() } else { forward(from, to) }
                    })
                } else if done || err != nil {
                    close()
                } else {
                    forward(from, to)
                }
            }
        }
        forward(a, b)
        forward(b, a)
    }
}

/// 只會成功設定一次的旗標
final class ManagedAtomicFlag {
    private var v = false
    private let lock = NSLock()
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if v { return false }
        v = true
        return true
    }
}
