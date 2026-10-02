import Foundation
import Darwin

public struct ResourceConfiguration: Codable, Equatable, Sendable {
    public var maximumPendingSegments: Int
    public var maximumPendingDuration: TimeInterval
    public var maximumPendingAudioBytes: UInt64
    public var maximumRecordingDuration: TimeInterval
    public var maximumLocalBytes: UInt64
    public var automaticSendingWindow: TimeInterval

    public init(maximumPendingSegments: Int = 20,
                maximumPendingDuration: TimeInterval = 1_800,
                maximumPendingAudioBytes: UInt64 = 268_435_456,
                maximumRecordingDuration: TimeInterval = 300,
                maximumLocalBytes: UInt64 = 5_368_709_120,
                automaticSendingWindow: TimeInterval = 86_400) {
        self.maximumPendingSegments = maximumPendingSegments
        self.maximumPendingDuration = maximumPendingDuration
        self.maximumPendingAudioBytes = maximumPendingAudioBytes
        self.maximumRecordingDuration = maximumRecordingDuration
        self.maximumLocalBytes = maximumLocalBytes
        self.automaticSendingWindow = automaticSendingWindow
    }

    public var queueLimits: QueueLimits {
        get throws {
            try validate()
            return QueueLimits(maximumPendingSegments: maximumPendingSegments,
                               maximumPendingDuration: maximumPendingDuration,
                               maximumPendingAudioBytes: maximumPendingAudioBytes)
        }
    }

    public var recordingLimits: RecordingLimits {
        get throws {
            try validate()
            return RecordingLimits(maximumDuration: maximumRecordingDuration, maximumLocalBytes: maximumLocalBytes)
        }
    }

    public func isAutomaticSendingExpired(recordingEndedAt: Date, renewedAt: Date? = nil, now: Date = Date()) throws -> Bool {
        try validate()
        let anchor = renewedAt ?? recordingEndedAt
        let elapsed = now.timeIntervalSince(anchor)
        guard recordingEndedAt.timeIntervalSinceReferenceDate.isFinite,
              anchor.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, elapsed.isFinite else {
            throw ResourceSettingsError.invalidWindowAnchor
        }
        return elapsed > automaticSendingWindow
    }

    fileprivate func validate() throws {
        guard (1...100).contains(maximumPendingSegments) else { throw ResourceSettingsError.invalidPendingSegments }
        guard maximumPendingDuration.isFinite, (60...7_200).contains(maximumPendingDuration) else {
            throw ResourceSettingsError.invalidPendingDuration
        }
        guard (67_108_864...2_147_483_648).contains(maximumPendingAudioBytes) else {
            throw ResourceSettingsError.invalidPendingAudioBytes
        }
        guard maximumRecordingDuration.isFinite, (60...3_600).contains(maximumRecordingDuration) else {
            throw ResourceSettingsError.invalidRecordingDuration
        }
        guard (1_073_741_824...107_374_182_400).contains(maximumLocalBytes) else {
            throw ResourceSettingsError.invalidLocalBytes
        }
        guard automaticSendingWindow.isFinite, (3_600...604_800).contains(automaticSendingWindow) else {
            throw ResourceSettingsError.invalidAutomaticSendingWindow
        }
    }
}

public enum ResourceSettingsError: Error, Equatable, LocalizedError, Sendable {
    case invalidPendingSegments, invalidPendingDuration, invalidPendingAudioBytes
    case invalidRecordingDuration, invalidLocalBytes, invalidAutomaticSendingWindow
    case unreadableConfiguration, cannotSave
    case invalidWindowAnchor

    public var errorDescription: String? {
        switch self {
        case .invalidPendingSegments: "主积压片段数必须是 1–100 的整数；上一次有效值已保留。"
        case .invalidPendingDuration: "主积压累计时长必须是 1–120 分钟的有限数值；上一次有效值已保留。"
        case .invalidPendingAudioBytes: "主积压音频额度必须是 64–2048 MiB，并对应完整字节；上一次有效值已保留。"
        case .invalidRecordingDuration: "单段录音时长必须是 1–60 分钟的有限数值；上一次有效值已保留。"
        case .invalidLocalBytes: "全本地数据额度必须是 1–100 GiB，并对应完整字节；上一次有效值已保留。"
        case .invalidAutomaticSendingWindow: "自动发送时间窗必须是 1–168 小时的有限数值；上一次有效值已保留。"
        case .unreadableConfiguration: "资源配置无法读取；原文件已保留，请修复后保存。"
        case .cannotSave: "资源配置无法保存；上一次有效值已保留，请检查数据目录与磁盘空间。"
        case .invalidWindowAnchor: "无法确认录音结束或恢复时间，未发工作不能自动继续。"
        }
    }
}

@MainActor
public final class ResourceSettings {
    private let file: URL

    public init(file: URL) { self.file = file }

    public func load() throws -> ResourceConfiguration {
        guard file.isFileURL else { throw ResourceSettingsError.unreadableConfiguration }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return ResourceConfiguration()
            }
            throw ResourceSettingsError.unreadableConfiguration
        }
        do {
            let configuration = try JSONDecoder().decode(ResourceConfiguration.self, from: data)
            try validateConfiguration(configuration)
            return configuration
        } catch let error as ResourceSettingsError { throw error }
        catch { throw ResourceSettingsError.unreadableConfiguration }
    }

    public func save(_ configuration: ResourceConfiguration) throws {
        guard file.isFileURL else { throw ResourceSettingsError.cannotSave }
        try validateConfiguration(configuration)
        do { try persist(configuration) }
        catch { throw ResourceSettingsError.cannotSave }
    }

    private func persist(_ configuration: ResourceConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let files = FileManager.default
        let folder = file.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try files.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o700 == 0o700 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let staged = folder.appendingPathComponent(".resource-settings-\(UUID()).tmp")
        defer { try? files.removeItem(at: staged) }
        guard files.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        // 所有可能失败的权限工作先完成，原子替换成功后不再抛保存失败。
        guard staged.path.withCString({ source in
            file.path.withCString { destination in Darwin.rename(source, destination) }
        }) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    public func validateConfiguration(_ configuration: ResourceConfiguration) throws {
        try configuration.validate()
    }
}
