import Foundation
import Security

public struct KeychainDataKey: LocalDataKeyProviding {
    private let service: String
    private let account = "local-history-key-v1"

    public init(service: String = "io.github.patrick-fu.queued-dictation.local-data") {
        self.service = service
    }

    public func loadKey(createIfMissing: Bool) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, createIfMissing else { throw DictationError.dataKeyUnavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DictationError.dataKeyUnavailable
        }
        let data = Data(bytes)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                  kSecValueData as String: data]
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try loadKey(createIfMissing: false) }
        guard added == errSecSuccess else { throw DictationError.dataKeyUnavailable }
        return data
    }
}
