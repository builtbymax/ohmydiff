import Foundation
import Security

/// API keys and tokens for ticket trackers, as generic passwords in the login Keychain.
///
/// Reading a secret can ask for Keychain access, so values are read only when a lookup needs them and then
/// kept for the session; Settings only checks whether one is saved, which never asks.
enum Keychain {
    enum Item: String {
        case linear
        case jira
    }

    private static let service = "\(AppVariant.bundleIdentifier).tickets"
    private static var cache: [Item: String] = [:]

    /// Whether a value is saved, without reading it.
    static func contains(_ item: Item) -> Bool {
        if cache[item] != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ item: Item) -> String? {
        if let value = cache[item] { return value }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        cache[item] = value
        return value
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
        cache[item] = nil
        guard !value.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return false }
        cache[item] = value
        return true
    }
}
