import Foundation
import Security

/// Stores the Aryeo and Claude keys in the iPhone's secure keychain (never in the app's files).
/// The app and the Home Screen widget share one keychain group (see the .entitlements files), so the widget
/// can read the Aryeo key. Items go into the first group listed there, and reads search every group.
/// "After first unlock" lets the widget refresh while the phone is locked.
enum Keychain {
    private static let service = "com.horizonhomemedia.shootdesk"

    static func get(_ account: String) -> String { read(account).value }

    /// The value plus the keychain's answer, so the widget can tell "no key saved" (errSecItemNotFound)
    /// from "phone hasn't been unlocked since restarting" (errSecInteractionNotAllowed).
    static func read(_ account: String) -> (value: String, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            return ("", status)
        }
        return (s, status)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum KeyName {
    static let aryeo = "aryeo"
    static let claude = "claude"
    static let stripe = "stripe"
}
