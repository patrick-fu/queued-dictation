import Foundation

public enum HotkeyConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case unreadableSettings, settingsUnavailable
    case unsupportedCombination(String)
    public var errorDescription: String? {
        switch self {
        case .unreadableSettings: "无法读取已保存的快捷键设置，原设置已保留。请重新选择录音快捷键。"
        case .settingsUnavailable: "无法确认快捷键已保存，当前设置已回退；持久化未确认，请检查本机设置存储后重试。"
        case .unsupportedCombination(let reason): reason
        }
    }
}

@MainActor
public final class HotkeyConfigurationStore {
    private let defaults: UserDefaults
    private let key = "recordingHotkeyConfiguration"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() throws -> HotkeyConfiguration {
        guard let saved = defaults.object(forKey: key) else { return .init() }
        guard let data = saved as? Data else { throw HotkeyConfigurationError.unreadableSettings }
        do {
            let configuration = try JSONDecoder().decode(HotkeyConfiguration.self, from: data)
            try validate(configuration)
            return configuration
        }
        catch let error as HotkeyConfigurationError { throw error }
        catch { throw HotkeyConfigurationError.unreadableSettings }
    }

    public func save(_ configuration: HotkeyConfiguration) throws {
        try validate(configuration)
        let data = try JSONEncoder().encode(configuration)
        let previous = defaults.object(forKey: key)
        defaults.set(data, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == data else {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            // 恢复原始值后仍报告未确认；不能把内存回退当作磁盘持久化成功。
            _ = defaults.synchronize()
            throw HotkeyConfigurationError.settingsUnavailable
        }
    }

    private func validate(_ configuration: HotkeyConfiguration) throws {
        if case .combination(let combination) = configuration.binding, let reason = combination.validationMessage {
            throw HotkeyConfigurationError.unsupportedCombination(reason)
        }
    }
}
