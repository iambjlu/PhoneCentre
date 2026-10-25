import Foundation
import Security

/// 簡單的鑰匙圈存取（generic password）
enum Keychain {
    private static let service = "com.iambjlu.PhoneCentre"

    /// Dock 獨立視窗的子程序（簽章身分不同的副本）不碰鑰匙圈：每個副本都會各自跳出鑰匙圈授權。
    /// 需要密碼的動作（例如解鎖）改由主程式代辦。
    static func get(_ account: String) -> String? {
        if ChildMode.isChild { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        if ChildMode.isChild { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
