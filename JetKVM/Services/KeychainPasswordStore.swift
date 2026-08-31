import Foundation
import Security

enum KeychainPasswordStore {
    private static let service = "com.jetkvm.orbitkvm.device-passwords"

    static func password(for device: KVMDevice) -> String? {
        var query = baseQuery(for: device)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String, for device: KVMDevice) -> Bool {
        let data = Data(password.utf8)
        let query = baseQuery(for: device)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func removePassword(for device: KVMDevice) {
        SecItemDelete(baseQuery(for: device) as CFDictionary)
    }

    private static func baseQuery(for device: KVMDevice) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(device.host.lowercased()):\(device.port)"
        ]
    }
}
