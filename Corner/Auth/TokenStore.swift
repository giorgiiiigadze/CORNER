import Foundation
import Security

/// The refresh token, kept in the Keychain.
///
/// Not `UserDefaults`: a refresh token is a long-lived credential — it mints
/// access tokens for as long as it's valid — and `UserDefaults` is a plist in
/// the app container that any file-level backup or jailbroken read hands over
/// whole. The Keychain is encrypted at rest and the OS is the one holding it.
///
/// `afterFirstUnlock` rather than `whenUnlocked`, because the session engine can
/// be running with the phone propped face-down on a bench and the screen locked;
/// a token that becomes unreadable at that moment would end the workout with a
/// sign-in prompt nobody is holding the phone to answer.
nonisolated enum TokenStore {

    private static let service = "Giorgi.Corner.auth"
    private static let account = "refresh-token"

    static func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Delete-then-add rather than `SecItemUpdate`: the update path has to
        // handle "no existing item" anyway, and two calls that always work beat
        // one that works most of the time.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read() -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
