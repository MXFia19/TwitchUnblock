import Foundation
import Security

/// Jetons Twitch rangés dans le trousseau plutôt que dans UserDefaults :
/// un plist en clair se lit dans une sauvegarde iTunes/Finder ou avec un
/// gestionnaire de fichiers sur un appareil en sideload.
///
/// Si le trousseau refuse l'écriture (certaines signatures de sideload sans
/// le droit d'accès), on retombe sur UserDefaults : mieux vaut un jeton moins
/// protégé qu'une déconnexion à chaque lancement.
enum Keychain {
    private static let service = "com.mxfia19.TwitchUnblock.tokens"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return true }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Lecture d'un jeton : trousseau, sinon ancien emplacement UserDefaults
    /// (migré au passage s'il peut l'être).
    static func loadToken(_ key: String) -> String? {
        if let v = get(key) { return v }
        let ud = UserDefaults.standard
        guard let legacy = ud.string(forKey: key) else { return nil }
        if set(legacy, for: key) { ud.removeObject(forKey: key) }
        return legacy
    }

    /// Écriture d'un jeton : trousseau, UserDefaults seulement en repli.
    static func storeToken(_ value: String?, for key: String) {
        let ud = UserDefaults.standard
        if set(value, for: key) {
            ud.removeObject(forKey: key)
        } else if let value {
            ud.set(value, forKey: key)
        } else {
            ud.removeObject(forKey: key)
        }
    }
}
