import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case notFound
    case unexpected(OSStatus)
}

public enum Keychain {
    /// Reads the generic password stored under `service`. Never logs or persists it.
    public static func password(service: String) throws(KeychainError) -> String {
        guard !DebugFlags.current.skipsKeychain else { throw .notFound }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw .notFound }
        guard status == errSecSuccess else { throw .unexpected(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw .unexpected(errSecDecode)
        }
        return password
    }

    /// Stores `password` as the generic password of `service` and `account`: replaces an existing
    /// item, adds one otherwise. Never logs or persists it elsewhere. `label` names the item in Keychain
    /// Access; `thisDeviceOnly` keeps it readable only while the Mac is unlocked, and out of backups.
    public static func setPassword(
        _ password: String,
        service: String,
        account: String,
        label: String? = nil,
        thisDeviceOnly: Bool = false
    ) throws(KeychainError) {
        guard !DebugFlags.current.skipsKeychain else { return }
        // Updates whichever account holds the item, so one stored under another account is replaced.
        let existing: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let data = Data(password.utf8)
        var changes: [CFString: Any] = [kSecValueData: data]
        if let label { changes[kSecAttrLabel] = label }
        if thisDeviceOnly { changes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        let updateStatus = SecItemUpdate(existing as CFDictionary, changes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw .unexpected(updateStatus) }
        var attributes = existing.merging(changes) { _, change in change }
        attributes[kSecAttrAccount] = account
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw .unexpected(addStatus) }
    }

    /// Deletes the item of `service` and `account`; a missing item is not an error.
    static func deletePassword(service: String, account: String) {
        guard !DebugFlags.current.skipsKeychain else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes every item of `service`, whatever its account; a missing item is not an error.
    public static func deleteItems(service: String) {
        guard !DebugFlags.current.skipsKeychain else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
