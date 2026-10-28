import Foundation
import Security

/** Keeps the sign-in token in the Keychain so it survives app restarts. */
enum SessionStore {
    private static let service = "MusicSynq"
    private static let account = "session-token"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) {
        deleteToken()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            // Readable after the first unlock, so a notification action can use it while locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/** Where the MusicSynq server lives. Defaults to the build setting; can be changed in Settings. */
enum ServerSettings {
    private static let key = "serverURL"

    static var defaultURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MusicSynqServerURL") as? String
        return raw.flatMap(URL.init(string:)) ?? URL(string: "http://localhost:8080")!
    }

    static var url: URL {
        get { UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:)) ?? defaultURL }
        set {
            if newValue == defaultURL {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(newValue.absoluteString, forKey: key)
            }
        }
    }

    /** Accepts "myserver.com", "http://192.168.1.5:8080", etc. Returns nil if it isn't a usable URL. */
    static func parse(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}
