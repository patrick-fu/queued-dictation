import AVFAudio
import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct HotkeyRecordingBehaviorTests {
    @Test
    func storageQuotaRefusalAppearsAsTheRealRecordingResultWithoutAnEmptyHistoryEntry() async throws {
        let fixture = HotkeyFixture(limits: .init(maximumLocalBytes: 1))
        defer { fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { !fixture.controller.isTransitioning }
        #expect(fixture.app.state == .ready)
        #expect(fixture.controller.presentation == .result(DictationError.localStorageLimit.localizedDescription))
        #expect(try fixture.app.history().isEmpty)
    }

    @Test
    func captureFailureAppearsAsTheRealRecordingResultAndRetainsValidAudio() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.controller.presentation == .recording(duration: 0.5) }
        fixture.microphone.fail(AudioCaptureError.deviceChanged)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(fixture.controller.presentation == .result("音频采集已中断。"))
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func explicitListeningRetryRecoversAFailedFnRegistrationAfterPermissionIsAllowed() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.denyFn()
        fixture.keys.status.listenPermissionGranted = true
        fixture.controller.retryShortcutRegistration()
        #expect(fixture.controller.listenerStatus.recording == .ready)
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func appRecordingEntryStillWorksWithDeniedFnAndAnUnrelatedReleaseCannotStopIt() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.denyFn()
        fixture.controller.toggleRecordingFromApp()
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.keys.release(.fn)
        #expect(fixture.controller.presentation == .recording(duration: 0))
        fixture.microphone.emit(testAudio())
        fixture.controller.toggleRecordingFromApp()
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func aNewGestureWaitsForAudioDeviceStopAndCannotRestartFromAHeldKey() async throws {
        let fixture = HotkeyFixture()
        fixture.microphone.holdStop = true
        defer { fixture.microphone.acknowledgeStop(); fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.controller.presentation == .recording(duration: 0.5) }
        fixture.keys.release(.fn)
        #expect(fixture.controller.presentation == .finishing)
        fixture.keys.press(.fn)
        #expect(try fixture.app.history().isEmpty)
        fixture.microphone.acknowledgeStop()
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        fixture.keys.press(.fn, repeating: true)
        #expect(fixture.app.state == .ready)
        fixture.keys.release(.fn)
        fixture.microphone.holdStop = false
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().map(\.duration) == [0.5, 0.5])
    }

    @Test
    func unsupportedCombinationIsRejectedAndDoesNotReplaceASavedShortcut() throws {
        let domain = "HotkeyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = HotkeyConfigurationStore(defaults: defaults)
        let valid = HotkeyConfiguration(binding: .combination(.suggested), gesture: .tapToToggle)
        try settings.save(valid)
        #expect(throws: HotkeyConfigurationError.unsupportedCombination("该按键不支持组合键录音，请选择普通按键与修饰键。")) {
            try settings.save(.init(binding: .combination(.init(keyCode: 63, modifiers: [.command]))))
        }
        #expect(try settings.load() == valid)
    }

    @Test
    func savedCombinationAndGestureStillControlRecordingAfterSettingsReload() async throws {
        let domain = "HotkeyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = HotkeyConfigurationStore(defaults: defaults)
        let binding = HotkeyBinding.combination(.init(keyCode: 49, modifiers: [.control, .option]))
        try settings.save(.init(binding: binding, gesture: .tapToToggle))
        let restarted = HotkeyConfigurationStore(defaults: try #require(UserDefaults(suiteName: domain)))
        let fixture = HotkeyFixture(configuration: try restarted.load())
        defer { fixture.removeFiles() }
        fixture.keys.press(binding)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.keys.release(binding)
        #expect(fixture.controller.presentation == .recording(duration: 0))
        fixture.microphone.emit(testAudio())
        fixture.keys.press(binding)
        fixture.keys.release(binding)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func enteringACustomShortcutDoesNotStartRecordingAndRecordingResumesAfterEntry() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.controller.setShortcutEntryActive(true)
        fixture.keys.press(.fn)
        fixture.keys.release(.fn)
        #expect(fixture.app.state == .ready)
        #expect(!fixture.controller.isTransitioning)
        fixture.controller.setShortcutEntryActive(false)
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func deniedFnShowsTheReasonAndAConfiguredCombinationCanStillRecordWithoutListenPermission() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.denyFn()
        fixture.keys.press(.fn)
        fixture.keys.release(.fn)
        #expect(fixture.app.state == .ready)
        #expect(fixture.controller.presentation == .result(ControlledHotkeys.deniedMessage))
        let combination = HotkeyBinding.combination(.suggested)
        fixture.controller.updateConfiguration(.init(binding: combination))
        fixture.keys.press(.fn)
        fixture.keys.release(.fn)
        #expect(fixture.app.state == .ready)
        #expect(!fixture.controller.listenerStatus.listenPermissionGranted)
        fixture.keys.press(combination)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(combination)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func revokedFnListeningStopsAndSavesTheCurrentAudio() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.controller.presentation == .recording(duration: 0.5) }
        fixture.keys.denyFn()
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
        #expect(fixture.controller.listenerStatus.recording == .unavailable(ControlledHotkeys.deniedMessage))
    }

    @Test
    func shortcutCancellationDiscardsOnlyCurrentAudioAndKeepsEarlierHistoryDownload() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        let earlier = try #require(fixture.app.history().first)
        try fixture.app.exportAudio(earlier.id, to: fixture.download)
        let originalAudio = try Data(contentsOf: fixture.download)

        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.controller.presentation == .recording(duration: 0.5) }
        fixture.keys.cancel()
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history() == [earlier])
        try fixture.app.exportAudio(earlier.id, to: fixture.download)
        #expect(try Data(contentsOf: fixture.download) == originalAudio)
        #expect(fixture.controller.presentation == .result("已取消当前录音，音频已丢弃。"))
    }

    @Test
    func customCombinationInTapModeKeepsRecordingOnReleaseAndIgnoresKeyRepeat() async throws {
        let combination = HotkeyBinding.combination(.init(keyCode: 46, modifiers: [.command, .shift]))
        let fixture = HotkeyFixture(configuration: .init(binding: combination, gesture: .tapToToggle))
        defer { fixture.removeFiles() }
        fixture.keys.press(combination)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        let current = fixture.app.state
        fixture.keys.press(combination, repeating: true)
        fixture.keys.press(combination)
        fixture.keys.release(combination)
        #expect(fixture.app.state == current)
        fixture.microphone.emit(testAudio())
        fixture.keys.press(combination)
        fixture.keys.release(combination)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().first?.duration == 0.5)
    }

    @Test
    func releaseDuringPermissionPromptCannotStartCaptureAfterLateAuthorization() async throws {
        let fixture = HotkeyFixture()
        fixture.microphone.authorization = .notDetermined
        fixture.microphone.holdAuthorization = true
        defer { fixture.microphone.completeAuthorization(.authorized); fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { fixture.app.state == .requestingMicrophone }
        #expect(fixture.controller.presentation == .waitingForMicrophone)
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready }
        fixture.keys.press(.fn)
        fixture.keys.release(.fn)
        fixture.microphone.completeAuthorization(.authorized)
        try await waitUntil { !fixture.controller.isTransitioning }
        #expect(fixture.app.state == .ready)
        #expect(try fixture.app.history().isEmpty)

        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }
        #expect(try fixture.app.history().count == 1)
    }

    @Test
    func holdingFnRecordsAndReleaseSavesPlayableEncryptedAudio() async throws {
        let fixture = HotkeyFixture()
        defer { fixture.removeFiles() }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.app.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        try await waitUntil { fixture.app.state == .ready && !fixture.controller.isTransitioning }

        let entry = try #require(fixture.app.history().first)
        try fixture.app.exportAudio(entry.id, to: fixture.download)
        #expect(try AVAudioFile(forReading: fixture.download).length == 4_000)
        #expect(try savedFiles(fixture.directory).values.allSatisfy { $0.starts(with: Data("QDENC1".utf8)) })
        #expect(fixture.controller.presentation == .result("录音已加密保存，可从语音历史下载。"))
    }
}

@MainActor
private final class HotkeyFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let download = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    let microphone = HotkeyControlledMicrophone()
    let keys = ControlledHotkeys()
    let app: RecordingApplication
    let controller: HotkeyRecordingController

    init(configuration: HotkeyConfiguration = .init(), limits: RecordingLimits = .init()) {
        app = RecordingApplication(source: microphone, historyDirectory: directory, keys: TestDataKey(), limits: limits)
        controller = HotkeyRecordingController(recording: app, listener: keys, configuration: configuration)
        app.onChange = { [weak controller] in controller?.synchronize() }
    }

    func removeFiles() {
        controller.shutdown()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: download)
    }
}

@MainActor
private final class HotkeyControlledMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    var holdAuthorization = false
    var holdStop = false
    private var permissionRequest: CheckedContinuation<MicrophoneAuthorization, Never>?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization {
        if holdAuthorization { return await withCheckedContinuation { permissionRequest = $0 } }
        return authorization
    }
    func completeAuthorization(_ result: MicrophoneAuthorization) {
        authorization = result
        holdAuthorization = false
        permissionRequest?.resume(returning: result)
        permissionRequest = nil
    }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        guard continuation == nil else { throw DictationError.alreadyRecording }
        return AsyncThrowingStream { continuation = $0 }
    }
    func emit(_ audio: PCMChunk) { continuation?.yield(audio) }
    func fail(_ error: any Error) { continuation?.finish(throwing: error); continuation = nil }
    func stop() { if !holdStop { acknowledgeStop() } }
    func acknowledgeStop() { continuation?.finish(); continuation = nil }
}

@MainActor
private final class ControlledHotkeys: GlobalHotkeyListening {
    static let deniedMessage = "Fn 监听未获准。请允许输入监控，或改用组合键／App 录音入口。"
    var onEvent: ((HotkeyEvent) -> Void)?
    var onStatusChange: (() -> Void)?
    var status = HotkeyListenerStatus(recording: .ready, cancellation: .inactive,
                                     listenPermissionGranted: true, systemFn: .init())
    func configure(_ binding: HotkeyBinding) {
        status.recording = binding == .fn && !status.listenPermissionGranted ? .unavailable(Self.deniedMessage) : .ready
        onStatusChange?()
    }
    func setCancellationEnabled(_ enabled: Bool) {
        let next = enabled ? HotkeyAvailability.ready : .inactive
        guard status.cancellation != next else { return }
        status.cancellation = next
        onStatusChange?()
    }
    func setSuspended(_ suspended: Bool) {}
    func refreshStatus() {}
    func invalidate() {}
    func press(_ binding: HotkeyBinding, repeating: Bool = false) {
        onEvent?(.pressed(binding, isRepeat: repeating))
    }
    func release(_ binding: HotkeyBinding) { onEvent?(.released(binding)) }
    func cancel() { onEvent?(.cancelCurrentRecording) }
    func denyFn() {
        status.recording = .unavailable(Self.deniedMessage)
        status.listenPermissionGranted = false
        onStatusChange?()
    }
}
