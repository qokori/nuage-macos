//
//  Keychain.swift
//  Nuage
//
//  Secrets (account tokens) live in the login keychain, never in UserDefaults
//  or logs. One generic-password item per secret.
//

import Foundation
import Security

/// Where a provider keeps its token. Tests and previews can swap in memory storage.
protocol SecretStore {

    func read() -> String?
    func write(_ secret: String) throws
    func delete()

}

struct KeychainError: Error, LocalizedError {

    var status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Could not save the token in the Keychain: \(message)"
    }

}

struct KeychainSecretStore: SecretStore {

    var service: String
    var account: String
    /// Shown in Keychain Access.
    var label: String

    private var query: [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String) throws {
        let data = Data(secret.utf8)

        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }

}
