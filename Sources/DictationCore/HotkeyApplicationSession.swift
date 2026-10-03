import Foundation

@MainActor
public final class HotkeyApplicationSession {
    public let controller: HotkeyRecordingController
    public private(set) var configurationError: String?
    public private(set) var isTerminating = false
    public var onChange: (() -> Void)?
    public var requiresTerminationWait: Bool { recording.state != .ready || controller.isTransitioning }
    public var presentation: HotkeyRecordingPresentation {
        // startRecording 内先捕获交付目标；采集／授权状态回调前不显示胶囊。
        if isTerminating || controller.presentation == .starting { return .hidden }
        return controller.presentation
    }

    private let recording: RecordingApplication
    private let settings: HotkeyConfigurationStore
    private var shortcutEntryActive = false
    private var terminationTask: Task<Void, Never>?

    public init(recording: RecordingApplication, listener: any GlobalHotkeyListening, settings: HotkeyConfigurationStore) {
        self.recording = recording
        self.settings = settings
        let configuration: HotkeyConfiguration
        do { configuration = try settings.load() }
        catch { configuration = .init(); configurationError = error.localizedDescription }
        controller = HotkeyRecordingController(recording: recording, listener: listener, configuration: configuration)
        controller.onChange = { [weak self] in self?.onChange?() }
        if configurationError != nil { controller.setShortcutEntryActive(true) }
    }

    public func saveConfiguration(_ configuration: HotkeyConfiguration) throws {
        guard !isTerminating else { throw HotkeyConfigurationError.settingsUnavailable }
        try settings.save(configuration)
        configurationError = nil
        controller.updateConfiguration(configuration)
        controller.setShortcutEntryActive(shortcutEntryActive)
        onChange?()
    }

    public func setShortcutEntryActive(_ active: Bool) {
        shortcutEntryActive = active
        controller.setShortcutEntryActive(active || configurationError != nil || isTerminating)
    }

    public func synchronize() { controller.synchronize() }

    public func checkConditions() {
        guard !isTerminating else { return }
        recording.checkRecordingConditions()
        controller.refreshListenerStatus()
    }

    public func finishForTermination() async {
        if let terminationTask { await terminationTask.value; return }
        beginTermination()
        let controller = controller
        let recording = recording
        let task = Task {
            await controller.finishForTermination()
            recording.stopProcessing()
        }
        terminationTask = task
        await task.value
    }

    public func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        recording.prepareForTermination()
        controller.shutdown()
        onChange?()
    }

    public func shutdown() {
        beginTermination()
        controller.shutdown()
        recording.stopProcessing()
    }
}
