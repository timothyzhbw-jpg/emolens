import Foundation
import Security

/// 把 API Key 存进 macOS 钥匙串（登录钥匙串里的「通用密码」），不落在 UserDefaults 里。
enum Keychain {
    private static let service = "io.github.emolens.EmoLens"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 空字符串表示删除。
    static func save(_ value: String, for account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !value.isEmpty else { return }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "EmoLens · \(account) API Key"
        SecItemAdd(item as CFDictionary, nil)
    }
}
