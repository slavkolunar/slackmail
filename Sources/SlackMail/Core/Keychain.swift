import Foundation
import Security

/// Tajne (Slack token, Gmail app password) žive samo u macOS Keychain-u.
enum Keychain {
    static let service = "io.github.slavkolunar.slackmail"

    enum Key: String {
        case slackToken = "slack-user-token"
        case smtpPassword = "smtp-app-password"
    }

    static func get(_ key: Key) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ key: Key, _ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "SlackMail — \(key == .slackToken ? "Slack token" : "Gmail app password")"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
