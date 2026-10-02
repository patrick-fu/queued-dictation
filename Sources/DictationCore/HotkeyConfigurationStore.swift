import Foundation

public enum HotkeyConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case unreadableSettings, settingsUnavailable
    case unsupportedCombination(String)
    public var errorDescription: String? {
        switch self {
        case .unreadableSettings: "无法读取已保存的快捷键设置，原设置已保留。请重新选择录音快捷键。"
        case .settingsUnavailable: "无法保存快捷键设置，请检查本机设置存储。"
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
        guard let data = defaults.data(forKey: key) else { return .init() }
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
        defaults.set(data, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == data else {
            throw HotkeyConfigurationError.settingsUnavailable
        }
    }

    private func validate(_ configuration: HotkeyConfiguration) throws {
        if case .combination(let combination) = configuration.binding, let reason = combination.validationMessage {
            throw HotkeyConfigurationError.unsupportedCombination(reason)
        }
    }
}
