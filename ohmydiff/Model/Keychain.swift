import Foundation
import Security

/// API keys and tokens for ticket trackers, as generic passwords in the login Keychain.
enum Keychain {
    enum Item: String {
        case linear
        case jira
    }

    private static let service = "dev.koby.ohmydiff.tickets"

    static func read(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or removes the item when it is empty.
    @discardableResult
    static func write(_ value: String, for item: Item) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
