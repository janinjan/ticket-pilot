import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case notFound
    case unexpected(OSStatus)
}

public enum Keychain {
    /// Reads the generic password stored under `service`. Never logs or persists it.
    public static func password(service: String) throws(KeychainError) -> String {
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
}
