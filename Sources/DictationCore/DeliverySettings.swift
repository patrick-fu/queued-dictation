import Foundation

public enum DeliveryMode: String, Codable, CaseIterable, Sendable {
    case recordingTarget
    case currentCursor
}

public struct DeliveryConfiguration: Codable, Equatable, Sendable {
    public var mode: DeliveryMode
    public init(mode: DeliveryMode = .recordingTarget) { self.mode = mode }
}

public enum DeliverySettingsError: Error, Equatable, LocalizedError {
    case unreadableConfiguration, cannotSave
    public var errorDescription: String? {
        switch self {
        case .unreadableConfiguration: "上屏设置无法读取；原配置已保留，请重新选择并保存。"
        case .cannotSave: "上屏设置无法保存；上一次有效模式已保留。"
        }
    }
}

@MainActor
public final class DeliverySettings {
    private let file: URL
    public init(file: URL) { self.file = file }

    public func load() throws -> DeliveryConfiguration {
        do { return try JSONDecoder().decode(DeliveryConfiguration.self, from: Data(contentsOf: file)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return .init()
        } catch { throw DeliverySettingsError.unreadableConfiguration }
    }

    public func save(_ configuration: DeliveryConfiguration) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: file, options: .atomic)
        } catch { throw DeliverySettingsError.cannotSave }
    }
}
