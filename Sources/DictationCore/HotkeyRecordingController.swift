import Foundation

public enum HotkeyRecordingPresentation: Equatable, Sendable {
    case hidden, starting, waitingForMicrophone, finishing
    case recording(duration: TimeInterval)
    case result(String)
}

@MainActor
public final class HotkeyRecordingController {
    public private(set) var presentation = HotkeyRecordingPresentation.hidden
    public private(set) var configuration: HotkeyConfiguration
    public var isTransitioning: Bool { startTask != nil || endTask != nil || cancelTask != nil }
    public var onChange: (() -> Void)?
    public var listenerStatus: HotkeyListenerStatus { listener.status }

    private let recording: RecordingApplication
    private let listener: any GlobalHotkeyListening
    private var startTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var generation = 0
    private var activeGeneration: Int?
    private var recordingBeganWithShortcut = false
    private enum StopIntent { case save, discard }
    private var stopIntent: StopIntent?
    private var localNotice: String?
    private var held = false
    private var shortcutEntryActive = false
    private var holdGeneration: Int?
    private var displayedStatus: HotkeyListenerStatus?

    public init(recording: RecordingApplication, listener: any GlobalHotkeyListening,
                configuration: HotkeyConfiguration = .init()) {
        self.recording = recording
        self.listener = listener
        self.configuration = configuration
        listener.onEvent = { [weak self] in self?.receive($0) }
        listener.onStatusChange = { [weak self] in self?.listenerStatusDidChange() }
        listener.configure(configuration.binding)
    }

    public func synchronize() {
        let previous = presentation
        switch recording.state {
        case .ready:
            if isTransitioning { presentation = stopIntent == nil ? .starting : .finishing }
            else {
                presentation = (localNotice ?? recording.notice).map(HotkeyRecordingPresentation.result) ?? .hidden
                activeGeneration = nil
                recordingBeganWithShortcut = false
                stopIntent = nil
            }
        case .requestingMicrophone: presentation = .waitingForMicrophone
        case .recording(_, let duration):
            presentation = stopIntent == nil ? .recording(duration: duration) : .finishing
        }
        let statusChanged = displayedStatus != listener.status
        displayedStatus = listener.status
        listener.setCancellationEnabled(recording.state != .ready || isTransitioning)
        if previous != presentation || statusChanged { onChange?() }
    }

    public func shutdown() {
        listener.onEvent = nil
        listener.onStatusChange = nil
        listener.invalidate()
    }

    public func cancelCurrentRecording() {
        guard recording.state != .ready || startTask != nil else { return }
        requestStop(.discard)
    }

    public func toggleRecordingFromApp() {
        switch recording.state {
        case .ready:
            if startTask != nil, stopIntent == nil { requestStop(.save) }
            else if !isTransitioning { beginRecording(fromShortcut: false) }
        case .requestingMicrophone, .recording:
            if stopIntent == nil { requestStop(.save) }
        }
    }

    public func updateConfiguration(_ configuration: HotkeyConfiguration) {
        guard self.configuration != configuration else { return }
        if recordingBeganWithShortcut, activeGeneration != nil { requestStop(.save) }
        held = false
        holdGeneration = nil
        localNotice = nil
        self.configuration = configuration
        listener.configure(configuration.binding)
        synchronize()
    }

    public func refreshListenerStatus() {
        listener.refreshStatus()
        synchronize()
    }

    public func retryShortcutRegistration() {
        guard recording.state == .ready, !isTransitioning, !shortcutEntryActive else {
            refreshListenerStatus()
            return
        }
        listener.configure(configuration.binding)
        synchronize()
    }

    public func setShortcutEntryActive(_ active: Bool) {
        guard shortcutEntryActive != active else { return }
        shortcutEntryActive = active
        held = false
        holdGeneration = nil
        if active, recordingBeganWithShortcut, activeGeneration != nil { requestStop(.save) }
        listener.setSuspended(active)
        synchronize()
    }

    private func receive(_ event: HotkeyEvent) {
        switch event {
        case .pressed(let binding, let isRepeat):
            guard !shortcutEntryActive, binding == configuration.binding, !isRepeat, !held else { return }
            held = true
            guard listener.status.recording == .ready else {
                if case .unavailable(let reason) = listener.status.recording { localNotice = reason }
                synchronize()
                return
            }
            if configuration.gesture == .tapToToggle, recording.state != .ready || activeGeneration != nil {
                if stopIntent == nil { requestStop(.save) }
                return
            }
            guard recording.state == .ready, !isTransitioning else { return }
            beginRecording(fromShortcut: true)
            if configuration.gesture == .holdToRecord { holdGeneration = activeGeneration }
        case .released(let binding):
            guard binding == configuration.binding else { return }
            held = false
            let releasedGeneration = holdGeneration
            holdGeneration = nil
            guard configuration.gesture == .holdToRecord, releasedGeneration != nil,
                  releasedGeneration == activeGeneration else { return }
            requestStop(.save)
        case .cancelCurrentRecording:
            guard listener.status.cancellation == .ready else { return }
            cancelCurrentRecording()
        }
    }

    private func listenerStatusDidChange() {
        if listener.status.recording != .ready, recordingBeganWithShortcut, activeGeneration != nil { requestStop(.save) }
        synchronize()
    }

    private func beginRecording(fromShortcut: Bool) {
        generation += 1
        let attempt = generation
        activeGeneration = attempt
        recordingBeganWithShortcut = fromShortcut
        localNotice = nil
        stopIntent = nil
        startTask = Task { [weak self] in
            guard let self, self.activeGeneration == attempt else { return }
            if self.stopIntent == nil { _ = await self.recording.startRecording() }
            else { self.localNotice = self.stopIntent == .discard ? "已取消当前录音，未开始采集。" : "录音已结束，未开始采集。" }
            guard self.activeGeneration == attempt else { return }
            self.startTask = nil
            self.synchronize()
        }
        synchronize()
    }

    private func requestStop(_ intent: StopIntent) {
        if stopIntent != .discard { stopIntent = intent }
        if endTask != nil, intent == .discard, cancelTask == nil, recording.state != .ready {
            let attempt = activeGeneration
            cancelTask = Task { [weak self] in
                guard let self else { return }
                await self.recording.cancelCurrentRecording()
                guard self.activeGeneration == attempt else { return }
                self.cancelTask = nil
                self.synchronize()
            }
        }
        guard endTask == nil, recording.state != .ready else { synchronize(); return }
        let attempt = activeGeneration
        // 没有音频草稿时 finish 无法使迟到授权失效，必须取消该次启动。
        let mustCancel = stopIntent == .discard || recording.state == .requestingMicrophone
        endTask = Task { [weak self] in
            guard let self else { return }
            if mustCancel { await self.recording.cancelCurrentRecording() }
            else { await self.recording.finishRecording() }
            guard self.activeGeneration == attempt else { return }
            self.endTask = nil
            self.synchronize()
        }
        synchronize()
    }
}
