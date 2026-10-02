import Foundation
import Security

public enum ServiceAuthentication: String, Codable, Sendable {
    case none, bearerToken
}

public struct ModelService: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: String
    public var authentication: ServiceAuthentication
    public init(id: UUID = UUID(), name: String, baseURL: String, authentication: ServiceAuthentication) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.authentication = authentication
    }
}

public struct ModelRoleConfiguration: Codable, Equatable, Sendable {
    public var serviceID: UUID
    public var model: String
    public init(serviceID: UUID, model: String) { self.serviceID = serviceID; self.model = model }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var services: [ModelService]
    public var transcription: ModelRoleConfiguration?
    public var transcriptionTimeout: TimeInterval
    public init(services: [ModelService] = [], transcription: ModelRoleConfiguration? = nil,
                transcriptionTimeout: TimeInterval = 60) {
        self.services = services; self.transcription = transcription; self.transcriptionTimeout = transcriptionTimeout
    }
}

@MainActor
public final class ServiceSettings {
    private let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> ModelConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return ModelConfiguration() }
        do {
            let config = try JSONDecoder().decode(ModelConfiguration.self, from: Data(contentsOf: file))
            try validateConfiguration(config)
            return config
        } catch { throw TranscriptionFailure.invalidConfiguration }
    }
    public func save(_ configuration: ModelConfiguration) throws {
        try validateConfiguration(configuration)
        let data = try JSONEncoder().encode(configuration)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func validateConfiguration(_ configuration: ModelConfiguration) throws {
        guard configuration.transcriptionTimeout.isFinite, (5...600).contains(configuration.transcriptionTimeout),
              Set(configuration.services.map(\.id)).count == configuration.services.count else {
            throw TranscriptionFailure.invalidConfiguration
        }
        for service in configuration.services {
            guard let url = URLComponents(string: service.baseURL),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw TranscriptionFailure.invalidConfiguration }
        }
        if let role = configuration.transcription {
            guard !role.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  role.model.utf8.count <= 256, !role.model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  configuration.services.contains(where: { $0.id == role.serviceID }) else {
                throw TranscriptionFailure.invalidConfiguration
            }
        }
    }
}

@MainActor
public protocol ServiceCredentialStoring {
    func key(for serviceID: UUID) throws -> String?
    func saveKey(_ key: String?, for serviceID: UUID) throws
}

@MainActor
public struct KeychainServiceCredentials: ServiceCredentialStoring {
    private let namespace = "io.github.patrick-fu.queued-dictation.model-services"
    public init() {}
    public func key(for serviceID: UUID) throws -> String? {
        var query = query(serviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data, let value = String(data: bytes, encoding: .utf8) else {
            throw TranscriptionFailure.credentialsUnavailable
        }
        return value
    }
    public func saveKey(_ key: String?, for serviceID: UUID) throws {
        let item = query(serviceID)
        if let key {
            guard !key.isEmpty, key.utf8.count <= 8_192, !key.contains("\r"), !key.contains("\n") else {
                throw TranscriptionFailure.invalidConfiguration
            }
            let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            let status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var new = item
                new[kSecValueData as String] = Data(key.utf8)
                new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw TranscriptionFailure.credentialsUnavailable }
            } else if status != errSecSuccess { throw TranscriptionFailure.credentialsUnavailable }
        } else {
            let status = SecItemDelete(item as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TranscriptionFailure.credentialsUnavailable }
        }
    }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace,
         kSecAttrAccount as String: id.uuidString]
    }
}
