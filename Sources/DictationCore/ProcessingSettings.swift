import Foundation

public struct ProcessingConfiguration: Codable, Equatable, Sendable {
    public var maximumConcurrentMainRequests: Int
    public init(maximumConcurrentMainRequests: Int = 3) {
        self.maximumConcurrentMainRequests = maximumConcurrentMainRequests
    }
}

public enum ProcessingSettingsError: Error, Equatable, LocalizedError {
    case invalidConcurrency, unreadableConfiguration, cannotSave
    public var errorDescription: String? {
        switch self {
        case .invalidConcurrency: "主流程请求并发必须是 1–10 的整数；上一次有效值已保留。"
        case .unreadableConfiguration: "主流程请求配置无法读取；原配置已保留，请修复后保存。"
        case .cannotSave: "主流程请求配置无法保存；上一次有效值已保留。"
        }
    }
}

@MainActor
public final class ProcessingSettings {
    private let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> ProcessingConfiguration {
        do {
            let config = try JSONDecoder().decode(ProcessingConfiguration.self, from: Data(contentsOf: file))
            try validate(config)
            return config
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return ProcessingConfiguration()
        } catch let error as ProcessingSettingsError { throw error }
        catch { throw ProcessingSettingsError.unreadableConfiguration }
    }
    public func save(_ config: ProcessingConfiguration) throws {
        try validate(config)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: file, options: .atomic)
        } catch { throw ProcessingSettingsError.cannotSave }
    }
    private func validate(_ config: ProcessingConfiguration) throws {
        guard (1...10).contains(config.maximumConcurrentMainRequests) else { throw ProcessingSettingsError.invalidConcurrency }
    }
}
