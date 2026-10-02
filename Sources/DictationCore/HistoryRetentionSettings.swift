import Darwin
import Foundation

public enum HistoryRetentionPeriod: Int, CaseIterable, Codable, Sendable {
    case days7 = 7, days30 = 30, days90 = 90, days365 = 365, forever = 0

    public var title: String {
        self == .forever ? "永久" : "\(rawValue) 天"
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        guard let period = Self(rawValue: value) else { throw HistoryRetentionSettingsError.invalidPeriod }
        self = period
    }

    public func shouldExpire(recordedAt: Date, now: Date, isTerminal: Bool, hasActiveRequest: Bool) -> Bool {
        guard self != .forever, isTerminal, !hasActiveRequest else { return false }
        let age = now.timeIntervalSince(recordedAt)
        return age.isFinite && age >= Double(rawValue) * 86_400
    }
}

public enum HistoryRetentionSettingsError: Error, Equatable, LocalizedError, Sendable {
    case invalidPeriod, unreadableConfiguration, cannotSave

    public var errorDescription: String? {
        switch self {
        case .invalidPeriod: "历史保留期必须是 7、30、90、365 天或永久；原配置已保留。"
        case .unreadableConfiguration: "历史保留配置无法读取；原配置已保留，请修复后保存。"
        case .cannotSave: "历史保留配置无法保存；上一次有效值已保留。"
        }
    }
}

@MainActor
public final class HistoryRetentionSettings {
    private let file: URL
    public init(file: URL) { self.file = file }

    public func load() throws -> HistoryRetentionPeriod {
        guard file.isFileURL else { throw HistoryRetentionSettingsError.unreadableConfiguration }
        do {
            let data = try Data(contentsOf: file)
            let period = try JSONDecoder().decode(HistoryRetentionPeriod.self, from: data)
            guard ExactIntegerJSONFields.isRootInteger(in: data) else { throw HistoryRetentionSettingsError.invalidPeriod }
            return period
        }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return .days30 }
        catch let error as HistoryRetentionSettingsError { throw error }
        catch { throw HistoryRetentionSettingsError.unreadableConfiguration }
    }

    public func save(_ period: HistoryRetentionPeriod) throws {
        guard file.isFileURL else { throw HistoryRetentionSettingsError.cannotSave }
        let files = FileManager.default
        let parent = file.deletingLastPathComponent()
        let pending = parent.appendingPathComponent(".retention-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: pending) }
        do {
            let data = try JSONEncoder().encode(period)
            try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try files.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let mode = attributes[.posixPermissions] as? Int, mode & 0o700 == 0o700 else {
                throw HistoryRetentionSettingsError.cannotSave
            }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            guard files.createFile(atPath: pending.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw HistoryRetentionSettingsError.cannotSave
            }
            // 权限设定在原子替换之前完成，失败时不能已经修改生效值。
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            guard Darwin.rename(pending.path, file.path) == 0 else { throw HistoryRetentionSettingsError.cannotSave }
        } catch { throw HistoryRetentionSettingsError.cannotSave }
    }
}
