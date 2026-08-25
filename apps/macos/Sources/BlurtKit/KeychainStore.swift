import Foundation
import Security

/// API keys live in the login keychain and nowhere else.
///
/// Not UserDefaults, not a plist, not a `.env` — the whole pitch of this app is
/// that your key stays on your machine, and that promise is only as good as the
/// least careful place it gets written. See the privacy model in
/// docs/ARCHITECTURE.md.
enum KeychainStore {
    private static let service = "sh.blurt.Blurt"

    static func set(_ value: String?, for providerId: String) {
        // Delete first: SecItemUpdate needs a different code path and this is
        // simpler than branching on whether the item already exists.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }

        var add = query
        add[kSecValueData as String] = data
        // Available after first unlock, but never synced to iCloud or migrated
        // to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(for providerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Provider ids we offer a key field for. Local endpoints need no key.
    static let knownProviders = ["groq", "openai", "deepgram"]
}
