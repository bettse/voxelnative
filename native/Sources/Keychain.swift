import Foundation
import Security

/// Login passwords live in the Keychain (generic passwords, this app only,
/// device-only), not UserDefaults, which is a plain plist in the app container.
///
/// An unsigned simulator build has no Keychain access (writes fail with
/// errSecMissingEntitlement), so `available` probes once and callers fall
/// back to UserDefaults there instead of losing the password.
enum Keychain {
    private static let service = "VoxelNative.login"

    static let available: Bool = {
        let probe = "probe"
        guard set("1", for: probe), get(probe) == "1" else { return false }
        delete(probe)
        return true
    }()

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard st == errSecItemNotFound else { return st == errSecSuccess }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
