import Foundation
import Security

/// Пароли и passphrase в Keychain: service `com.macxterm.session`, account = UUID сессии.
enum Keychain {
    enum Kind: Sendable { case password, passphrase }
    static let service = "com.macxterm.session"

    private static func account(_ id: UUID, _ kind: Kind) -> String {
        kind == .password ? id.uuidString : id.uuidString + ".passphrase"
    }

    private static func baseQuery(_ id: UUID, _ kind: Kind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(id, kind)]
    }

    static func get(_ id: UUID, kind: Kind) -> String? {
        var q = baseQuery(id, kind)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ id: UUID, kind: Kind) -> Bool {
        var q = baseQuery(id, kind)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String, for id: UUID, kind: Kind) -> Bool {
        let data = Data(value.utf8)
        let q = baseQuery(id, kind)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "MacXterm SSH"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(_ id: UUID, kind: Kind) {
        SecItemDelete(baseQuery(id, kind) as CFDictionary)
    }

    static func deleteAll(for id: UUID) {
        delete(id, kind: .password)
        delete(id, kind: .passphrase)
    }
}
