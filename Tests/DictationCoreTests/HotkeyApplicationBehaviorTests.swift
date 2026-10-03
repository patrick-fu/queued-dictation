import AVFAudio
import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct HotkeyApplicationBehaviorTests {
    @Test
    func repeatingTheSameMicrophoneRefusalStartsAHiddenAttemptWhileConditionRefreshKeepsTheOldResult() async throws {
        let fixture = try HotkeyApplicationFixture()
        fixture.microphone.authorization = .denied
        defer { fixture.remove() }
        let refusal = HotkeyRecordingPresentation.result(DictationError.microphoneUnavailable.localizedDescription)
        fixture.keys.press(.fn)
        try await waitUntil { !fixture.session.controller.isTransitioning }
        fixture.keys.release(.fn)
        #expect(fixture.session.presentation == refusal)
        var refreshPresentations: [HotkeyRecordingPresentation] = []
        for _ in 0..<3 {
            fixture.session.checkConditions()
            refreshPresentations.append(fixture.session.presentation)
        }
        var attemptPresentations: [HotkeyRecordingPresentation] = []
        fixture.session.onChange = { [weak fixture] in
            guard let fixture else { return }
            attemptPresentations.append(fixture.session.presentation)
        }
        fixture.keys.press(.fn)
        #expect(fixture.session.presentation == .hidden)
        try await waitUntil { !fixture.session.controller.isTransitioning }
        fixture.keys.release(.fn)
        print("sameRefusal newAttempt=\(attemptPresentations) unrelatedRefresh=\(refreshPresentations)")
        #expect(attemptPresentations.first == .hidden)
        #expect(attemptPresentations.last == refusal)
        #expect(refreshPresentations.allSatisfy { $0 == refusal })
        #expect(try fixture.model.history().isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test(arguments: [true, false])
    func aQueuedMicrophoneGrantCannotCreateAudioAfterSynchronousTermination(grantQueuedBeforeBegin: Bool) async throws {
        let fixture = try HotkeyApplicationFixture()
        fixture.microphone.authorization = .notDetermined
        fixture.microphone.holdAuthorization = true
        fixture.microphone.audioOnStart = testAudio()
        defer { fixture.microphone.completeAuthorization(.authorized); fixture.remove() }
        fixture.keys.press(.fn)
        try await waitUntil { fixture.model.state == .requestingMicrophone }
        if grantQueuedBeforeBegin { fixture.microphone.completeAuthorization(.authorized) }
        fixture.session.beginTermination()
        #expect(fixture.model.state == .ready)
        if !grantQueuedBeforeBegin { fixture.microphone.completeAuthorization(.authorized) }
        let termination = Task { await fixture.session.finishForTermination() }
        await termination.value
        let history = try fixture.model.history()
        print("queuedGrant beforeBegin=\(grantQueuedBeforeBegin) history=\(history.count) requests=\(fixture.server.requests.count)")
        if let entry = history.first {
            try fixture.model.exportAudio(entry.id, to: fixture.audioDownload)
            print("lateCapture WAVFrames=\(try AVAudioFile(forReading: fixture.audioDownload).length)")
        }
        #expect(fixture.model.state == .ready)
        #expect(history.isEmpty)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.session.controller.listenerStatus.recording == .inactive)
    }

    @Test
    func terminationPreservesActiveAudioWithoutSendingANewASRRequestEvenDuringASlowRender() async throws {
        let fixture = try HotkeyApplicationFixture()
        defer { fixture.remove() }
        fixture.model.onChange = { [weak fixture] in
            guard let fixture else { return }
            fixture.session.synchronize()
            if fixture.session.isTerminating,
               (try? fixture.model.history().contains { $0.transcription?.status == .inFlight }) == true {
                // 同步窗口／表格刷新可以让已经启动的网络线程先交付上传。
                usleep(50_000)
            }
        }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.session.presentation == .recording(duration: 0.5) }
        #expect(fixture.server.requests.isEmpty)
        fixture.session.beginTermination()
        await fixture.session.finishForTermination()
        let entry = try #require(fixture.model.history().first)
        try fixture.model.exportAudio(entry.id, to: fixture.audioDownload)
        let frames = try AVAudioFile(forReading: fixture.audioDownload).length
        print("activePrefix WAVFrames=\(frames) newRequests=\(fixture.server.requests.count)")
        for request in fixture.server.requests {
            print("postExit request=\(request.path) includesGeneratedPCM=\(request.body.range(of: testAudio().samples) != nil)")
        }
        #expect(frames == 4_000)
        #expect(try Data(contentsOf: fixture.audioDownload).suffix(testAudio().samples.count) == testAudio().samples)
        #expect(entry.transcription?.attemptID == nil)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.delivery.documents.isEmpty)
        #expect(fixture.model.state == .ready)
        #expect(!fixture.session.requiresTerminationWait)
        fixture.session.controller.toggleRecordingFromApp()
        fixture.keys.press(.fn)
        #expect(fixture.model.state == .ready)
        #expect(fixture.session.controller.listenerStatus.recording == .inactive)
    }

    @Test
    func aNonDataSavedShortcutIsReportedAndRetainedInsteadOfSilentlyEnablingFn() throws {
        let fixture = try HotkeyApplicationFixture(storedValue: "unexpected persisted value")
        defer { fixture.remove() }
        #expect(fixture.session.configurationError == HotkeyConfigurationError.unreadableSettings.localizedDescription)
        #expect(fixture.defaults.string(forKey: "recordingHotkeyConfiguration") == "unexpected persisted value")
        fixture.keys.press(.fn)
        #expect(fixture.model.state == .ready)
        #expect(fixture.session.controller.listenerStatus.recording == .inactive)
    }

    @Test
    func listenerAndMicrophoneRevocationKeepAudioAndTheAppEntryWorksAfterPermissionRecovers() async throws {
        let fixture = try HotkeyApplicationFixture()
        defer { fixture.remove() }
        fixture.keys.press(.fn)
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.session.presentation == .recording(duration: 0.5) }
        fixture.keys.revokeFn()
        fixture.session.checkConditions()
        try await waitUntil { fixture.server.requests.count == 1 && !fixture.session.controller.isTransitioning }
        let a = try #require(fixture.model.history().first)
        #expect(fixture.session.controller.listenerStatus.recording == .unavailable("Fn 监听未获准，请使用组合键或 App 录音入口。"))
        let binding = HotkeyBinding.combination(.suggested)
        try fixture.session.saveConfiguration(.init(binding: binding))
        fixture.microphone.authorization = .denied
        fixture.session.checkConditions()
        fixture.keys.press(binding)
        try await waitUntil { !fixture.session.controller.isTransitioning }
        fixture.keys.release(binding)
        #expect(fixture.session.presentation == .result(DictationError.microphoneUnavailable.localizedDescription))
        #expect(try fixture.model.history().map(\.id) == [a.id])

        fixture.microphone.authorization = .authorized
        fixture.session.checkConditions()
        fixture.session.controller.toggleRecordingFromApp()
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.session.controller.toggleRecordingFromApp()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(text: "失联前 A 保留。")
        try await waitUntil { fixture.delivery.documents["口述目标"] == "失联前 A 保留。" }
        fixture.server.reply(text: "权限恢复后 App 录音 B 完成。", index: 1)
        try await waitUntil { fixture.delivery.documents["口述目标"] == "失联前 A 保留。权限恢复后 App 录音 B 完成。" }
        #expect(try fixture.model.history().count == 2)
        #expect(try fixture.model.history().allSatisfy { $0.frameCount == 4_000 && $0.disposition == .completed })
    }

    @Test
    func failedSettingsSaveCannotEnableShortcutsFromInvalidStoredData() async throws {
        let original = Data("invalid settings remain".utf8)
        let fixture = try HotkeyApplicationFixture(storedValue: original)
        defer { fixture.remove() }
        fixture.defaults.rejectSynchronization = true
        let binding = HotkeyBinding.combination(.suggested)
        #expect(throws: HotkeyConfigurationError.settingsUnavailable) {
            try fixture.session.saveConfiguration(.init(binding: binding))
        }
        #expect(fixture.session.configurationError == HotkeyConfigurationError.unreadableSettings.localizedDescription)
        #expect(fixture.defaults.data(forKey: "recordingHotkeyConfiguration") == original)
        fixture.keys.press(binding)
        #expect(fixture.model.state == .ready)
        #expect(fixture.session.controller.listenerStatus.recording == .inactive)
        fixture.defaults.rejectSynchronization = false
        try fixture.session.saveConfiguration(.init(binding: binding))
        fixture.keys.press(binding)
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(binding)
        try await waitUntil { fixture.server.requests.count == 1 }
        fixture.server.reply(text: "保存恢复后入口才生效。")
        try await waitUntil { fixture.delivery.documents["口述目标"] == "保存恢复后入口才生效。" }
    }

    @Test
    func terminatingBeforeTheStartTaskRunsNeverCapturesAndRemovesBothShortcutEntrances() async throws {
        let fixture = try HotkeyApplicationFixture()
        defer { fixture.remove() }
        fixture.keys.press(.fn)
        #expect(fixture.session.requiresTerminationWait)
        await fixture.session.finishForTermination()
        fixture.keys.press(.fn)
        fixture.keys.cancel()
        fixture.session.controller.toggleRecordingFromApp()
        #expect(fixture.model.state == .ready)
        #expect(!fixture.session.requiresTerminationWait)
        #expect(fixture.session.presentation == .hidden)
        #expect(fixture.session.controller.listenerStatus.recording == .inactive)
        #expect(fixture.session.controller.listenerStatus.cancellation == .inactive)
        #expect(try fixture.model.history().isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test
    func terminatingDuringMicrophonePermissionDoesNotWaitForTheDialogOrAcceptLateCapture() async throws {
        let fixture = try HotkeyApplicationFixture()
        fixture.microphone.authorization = .notDetermined
        fixture.microphone.holdAuthorization = true
        defer { fixture.microphone.completeAuthorization(.authorized); fixture.remove() }
        fixture.keys.press(.fn)
        try await waitUntil { fixture.model.state == .requestingMicrophone }
        let termination = Task { await fixture.session.finishForTermination() }
        try await waitUntil { fixture.session.isTerminating && !fixture.session.requiresTerminationWait }
        await termination.value
        fixture.microphone.completeAuthorization(.authorized)
        await Task.yield()
        fixture.microphone.emit(testAudio())
        fixture.keys.release(.fn)
        #expect(fixture.model.state == .ready)
        #expect(try fixture.model.history().isEmpty)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.session.controller.listenerStatus.recording == .inactive)
    }

    @Test
    func cancellingBWhileASRIsPendingKeepsARequestAndAHistoryValid() async throws {
        let binding = HotkeyBinding.combination(.suggested)
        let fixture = try HotkeyApplicationFixture(configuration: .init(binding: binding, gesture: .tapToToggle))
        defer { fixture.remove() }
        fixture.keys.press(binding)
        fixture.keys.release(binding)
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.press(binding)
        fixture.keys.release(binding)
        try await waitUntil { fixture.server.requests.count == 1 && !fixture.session.controller.isTransitioning }
        let a = try #require(fixture.model.history().first)
        #expect(a.transcription?.status == .inFlight)
        fixture.keys.press(binding)
        fixture.keys.release(binding)
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        try await waitUntil { fixture.session.presentation == .recording(duration: 0.5) }
        fixture.keys.cancel()
        try await waitUntil { fixture.model.state == .ready && !fixture.session.controller.isTransitioning }
        #expect(try fixture.model.history().map(\.id) == [a.id])
        #expect(try fixture.model.history().first?.transcription?.status == .inFlight)
        fixture.server.reply(text: "取消 B 后 A 的请求仍能完成。")
        try await waitUntil { fixture.delivery.documents["口述目标"] == "取消 B 后 A 的请求仍能完成。" }
        #expect(try fixture.model.history().first?.rawTranscription == "取消 B 后 A 的请求仍能完成。")
        #expect(fixture.server.requests.count == 1)
    }

    @Test
    func invalidSavedShortcutRemainsIntactAndOnlyAnExplicitSuccessfulSaveEnablesGlobalRecording() async throws {
        let invalid = Data("{not valid json}".utf8)
        let fixture = try HotkeyApplicationFixture(storedValue: invalid)
        defer { fixture.remove() }
        #expect(fixture.session.configurationError == HotkeyConfigurationError.unreadableSettings.localizedDescription)
        #expect(fixture.defaults.data(forKey: "recordingHotkeyConfiguration") == invalid)
        fixture.keys.press(.fn)
        #expect(fixture.model.state == .ready)
        fixture.session.controller.toggleRecordingFromApp()
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.session.controller.toggleRecordingFromApp()
        try await waitUntil { fixture.server.requests.count == 1 && !fixture.session.controller.isTransitioning }
        #expect(fixture.defaults.data(forKey: "recordingHotkeyConfiguration") == invalid)
        fixture.server.reply(text: "设置损坏时 App 入口仍可使用。")
        try await waitUntil { fixture.delivery.documents["口述目标"] == "设置损坏时 App 入口仍可使用。" }

        let binding = HotkeyBinding.combination(.suggested)
        try fixture.session.saveConfiguration(.init(binding: binding))
        #expect(fixture.session.configurationError == nil)
        #expect(try fixture.settings.load() == .init(binding: binding))
        fixture.keys.press(binding)
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        fixture.keys.release(binding)
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(text: "保存有效组合键后继续录音。", index: 1)
        try await waitUntil { (try? fixture.model.history().contains { $0.rawTranscription == "保存有效组合键后继续录音。" }) == true }
        #expect(try fixture.model.history().count == 2)
    }

    @Test(arguments: [HotkeyBinding.fn, .combination(.suggested)], [HotkeyGesture.holdToRecord, .tapToToggle])
    func shortcutRecordsAudioAndCapturesTheTargetBeforeShowingTheCapsuleThenDeliversRealASRText(binding: HotkeyBinding, gesture: HotkeyGesture) async throws {
        let fixture = try HotkeyApplicationFixture(configuration: .init(binding: binding, gesture: gesture))
        defer { fixture.remove() }
        fixture.delivery.frontDocument = "口述目标"
        fixture.session.onChange = {
            if fixture.session.presentation != .hidden { fixture.delivery.frontDocument = "状态出现后选择的窗口" }
        }
        fixture.keys.press(binding)
        if gesture == .tapToToggle { fixture.keys.release(binding) }
        try await waitUntil { if case .recording = fixture.model.state { return true }; return false }
        fixture.microphone.emit(testAudio())
        if gesture == .tapToToggle { fixture.keys.press(binding) }
        fixture.keys.release(binding)
        try await waitUntil { fixture.server.requests.count == 1 }
        let request = try #require(fixture.server.requests.first)
        #expect(request.path == "/v1/audio/transcriptions")
        #expect(request.body.range(of: Data("fixture-asr".utf8)) != nil)
        #expect(request.body.range(of: Data("RIFF".utf8)) != nil)
        #expect(request.body.range(of: testAudio().samples) != nil)
        fixture.server.reply(text: "从实际本机请求得到的原文。")
        try await waitUntil { fixture.delivery.documents["口述目标"] == "从实际本机请求得到的原文。" }
        let entry = try #require(fixture.model.history().first)
        #expect(entry.rawTranscription == "从实际本机请求得到的原文。")
        #expect(entry.disposition == .completed)
        #expect(fixture.delivery.documents["状态出现后选择的窗口"] == nil)
        try fixture.model.exportAudio(entry.id, to: fixture.audioDownload)
        #expect(try AVAudioFile(forReading: fixture.audioDownload).length == 4_000)
    }
}

@MainActor
private final class HotkeyApplicationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "HotkeyApplicationTests.\(UUID())"
    let microphone = ApplicationMicrophone()
    let delivery = HotkeyDocumentDelivery()
    let keys = ApplicationHotkeys()
    let server: HotkeyASRServer
    let model: RecordingApplication
    let settings: HotkeyConfigurationStore
    let defaults: ApplicationSettingsDefaults
    let session: HotkeyApplicationSession
    var audioDownload: URL { root.appendingPathComponent("download.wav") }

    init(configuration: HotkeyConfiguration = .init(), storedValue: Any? = nil) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = try HotkeyASRServer()
        defaults = try #require(ApplicationSettingsDefaults(suiteName: domain))
        settings = HotkeyConfigurationStore(defaults: defaults)
        if let storedValue { defaults.set(storedValue, forKey: "recordingHotkeyConfiguration") }
        else { try settings.save(configuration) }
        let services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        let serviceID = UUID()
        try services.save(ModelConfiguration(services: [ModelService(id: serviceID, name: "受控本机服务", baseURL: server.baseURL + "/v1", authentication: .none)],
                                            transcription: .init(serviceID: serviceID, model: "fixture-asr")))
        model = RecordingApplication(source: microphone, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
                                     transcription: .init(settings: services, credentials: TestServiceCredentials(), delivery: delivery))
        session = HotkeyApplicationSession(recording: model, listener: keys, settings: settings)
        model.onChange = { [weak session] in session?.synchronize() }
    }

    func remove() {
        session.onChange = nil
        model.onChange = nil
        session.shutdown()
        microphone.stop()
        server.stop()
        defaults.rejectSynchronization = false
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ApplicationSettingsDefaults: UserDefaults, @unchecked Sendable {
    var rejectSynchronization = false
    override func synchronize() -> Bool { rejectSynchronization ? false : super.synchronize() }
}

@MainActor
private final class HotkeyDocumentDelivery: TextDelivering {
    var frontDocument = "口述目标"
    var documents: [String: String] = [:]
    private var targets: [TextDeliveryTarget: String] = [:]
    func captureTarget() -> TextDeliveryTarget? {
        let target = TextDeliveryTarget()
        targets[target] = frontDocument
        return target
    }
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard let document = targets[target] else { return .manual }
        documents[document, default: ""] += text
        return .delivered
    }
    func releaseTarget(_ target: TextDeliveryTarget) { targets[target] = nil }
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult { documents[frontDocument, default: ""] += text; return .delivered }
    func copy(_ text: String) {}
}

@MainActor
private final class ApplicationHotkeys: GlobalHotkeyListening {
    var onEvent: ((HotkeyEvent) -> Void)?
    var onStatusChange: (() -> Void)?
    var status = HotkeyListenerStatus(recording: .inactive, cancellation: .inactive,
                                     listenPermissionGranted: true, systemFn: .init())
    private var binding: HotkeyBinding?
    private var suspended = false
    private var invalidated = false
    func configure(_ binding: HotkeyBinding) { self.binding = binding; refreshStatus() }
    func setCancellationEnabled(_ enabled: Bool) {
        let next = enabled && !suspended && !invalidated ? HotkeyAvailability.ready : .inactive
        if status.cancellation != next { status.cancellation = next; onStatusChange?() }
    }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended; refreshStatus() }
    func refreshStatus() {
        let next: HotkeyAvailability = invalidated || suspended ? .inactive
            : binding == .fn && !status.listenPermissionGranted ? .unavailable("Fn 监听未获准，请使用组合键或 App 录音入口。") : .ready
        if status.recording != next { status.recording = next; onStatusChange?() }
    }
    func invalidate() { invalidated = true; refreshStatus(); status.cancellation = .inactive }
    func press(_ binding: HotkeyBinding) {
        guard !invalidated, !suspended, self.binding == binding, status.recording == .ready else { return }
        onEvent?(.pressed(binding, isRepeat: false))
    }
    func release(_ binding: HotkeyBinding) {
        guard !invalidated, !suspended, self.binding == binding, status.recording == .ready else { return }
        onEvent?(.released(binding))
    }
    func cancel() { if status.cancellation == .ready { onEvent?(.cancelCurrentRecording) } }
    func revokeFn() { status.listenPermissionGranted = false }
}

private final class HotkeyASRServer: @unchecked Sendable {
    struct Request: Sendable { let path: String; let body: Data }
    private let lock = NSLock()
    private let listener: Int32
    private var received: [Request] = []
    private var connections: [Int32] = []
    private var receiving: Int32?
    private var stopped = false
    let baseURL: String
    var requests: [Request] { lock.withLock { received } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw HotkeyServerError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw HotkeyServerError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(listener); throw HotkeyServerError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "hotkey-asr-listener").async { [self] in acceptRequests() }
    }

    func reply(text: String, index: Int = 0) {
        lock.withLock {
            guard !stopped, connections.indices.contains(index) else { return }
            let body = try! JSONSerialization.data(withJSONObject: ["text": text])
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            let connection = connections[index]
            response.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = send(connection, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { return }
                    sent += count
                }
            }
            close(connection)
            connections[index] = -1
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            shutdown(listener, SHUT_RDWR)
            if let receiving { shutdown(receiving, SHUT_RDWR) }
            for connection in connections where connection >= 0 { close(connection) }
            connections = []
        }
    }

    private func acceptRequests() {
        defer { close(listener) }
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            let mayRead = lock.withLock {
                if stopped { close(connection); return false }
                receiving = connection
                return true
            }
            guard mayRead else { return }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var headerEnd: Int?
            var path = ""
            var expected = 0
            while bytes.count < 2 * 1_024 * 1_024 {
                let count = recv(connection, &buffer, buffer.count, 0)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
                if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
                   let header = String(data: bytes.prefix(end), encoding: .utf8) {
                    headerEnd = end
                    let lines = header.components(separatedBy: "\r\n")
                    path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
                    expected = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                }
                if let headerEnd, bytes.count - headerEnd >= expected { break }
            }
            lock.withLock {
                receiving = nil
                guard !stopped, let headerEnd, bytes.count - headerEnd == expected else { close(connection); return }
                received.append(.init(path: path, body: bytes.suffix(from: headerEnd)))
                connections.append(connection)
            }
        }
    }
}

private enum HotkeyServerError: Error { case socket }

@MainActor
private final class ApplicationMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    var holdAuthorization = false
    var audioOnStart: PCMChunk?
    private var permission: CheckedContinuation<MicrophoneAuthorization, Never>?
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization {
        if holdAuthorization { return await withCheckedContinuation { permission = $0 } }
        return authorization
    }
    func completeAuthorization(_ value: MicrophoneAuthorization) {
        authorization = value
        holdAuthorization = false
        permission?.resume(returning: value)
        permission = nil
    }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        let audio = AsyncThrowingStream<PCMChunk, Error> { stream = $0 }
        if let audioOnStart { stream?.yield(audioOnStart) }
        return audio
    }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}
