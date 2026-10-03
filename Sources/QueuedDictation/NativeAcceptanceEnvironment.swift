#if NATIVE_ACCEPTANCE
import AppKit
import CryptoKit
import DictationCore
import Darwin
import Foundation

@MainActor
final class NativeAcceptanceEnvironment {
    let root: URL
    let runID: String
    let sourceSHA: String
    let baseURL: URL
    let inputMode: CoachInputMode
    let fakeServiceKey: String
    let defaults = NativeMemoryDefaults()
    let credentials = NativeServiceCredentials()
    let dataKeys = NativeDataKey()
    private let trace: NativeAppTrace
    private var currentRecording: UUID?
    private var recordingIndex = 0
    private var commandInProgress = false
    private var consumedCommands: Set<UUID> = []

    static func required() -> NativeAcceptanceEnvironment {
        do { return try NativeAcceptanceEnvironment() }
        catch { fatalError("Native acceptance configuration is invalid; production storage was not opened.") }
    }
    init() throws {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "QDNativeAcceptanceRoot") as? String, name.hasPrefix("/"),
              let source = Bundle.main.object(forInfoDictionaryKey: "QDNativeAcceptanceSourceCommit") as? String,
              source.count == 40, source.allSatisfy({ $0.isHexDigit }) else { throw NativeError.configuration }
        root = URL(fileURLWithPath: name, isDirectory: true); sourceSHA = source
        let properties = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw NativeError.configuration }
        let data = try Data(contentsOf: root.appendingPathComponent("native-ready.json"))
        guard data.count <= 16_384, let ready = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ready["schema_version"] as? Int == 1,
              let run = ready["run_id"] as? String, UUID(uuidString: run) != nil,
              let endpoint = ready["base_url"] as? String, let url = URL(string: endpoint),
              url.scheme == "http", url.host == "localhost", (1...65_535).contains(url.port ?? 0),
              url.path == "/v1", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              ready["asr_model"] as? String == "qd-native-asr", ready["polish_model"] as? String == "qd-native-polish",
              ready["coach_model"] as? String == "qd-native-coach", let pairs = ready["pairs"] as? Int, pairs >= 30,
              let mode = CoachInputMode(rawValue: ready["coach_input_mode"] as? String ?? "text"),
              ["native_physical", "synthetic_contract_fixture"].contains(ready["evidence_origin"] as? String ?? ""),
              let fakeKey = ready["fake_service_key"] as? String, fakeKey == "native-acceptance-fake-key" else { throw NativeError.configuration }
        runID = run; baseURL = url; inputMode = mode
        fakeServiceKey = fakeKey
        trace = try NativeAppTrace(root: root, runID: run)
        defaults.set(true, forKey: "didDismissIntroduction")
        NativeLocalURLProtocol.origin.withLock { $0 = url }
    }
    var vault: URL { root.appendingPathComponent("vault") }
    var settings: URL { root.appendingPathComponent("settings") }
    var network: URLSessionConfiguration { NativeLocalURLProtocol.configuration() }
    func initialize(service: ServiceSettings, polish: PolishSettings, coach: CoachSettings) throws {
        guard !FileManager.default.fileExists(atPath: vault.path), !FileManager.default.fileExists(atPath: settings.path) else { throw NativeError.configuration }
        let entry = ModelService(name: "Native acceptance localhost", baseURL: baseURL.absoluteString, authentication: .bearerToken)
        try credentials.saveKey(fakeServiceKey, for: entry.id)
        try service.save(.init(services: [entry], transcription: .init(serviceID: entry.id, model: "qd-native-asr")))
        try polish.save(.init(enabled: true, role: .init(serviceID: entry.id, model: "qd-native-polish")))
        try coach.save(.init(enabled: true, role: .init(serviceID: entry.id, model: "qd-native-coach"), inputMode: inputMode))
    }
    func boot() { trace.record("boot", fields: ["source_sha": sourceSHA, "main_limit": 3, "coach_limit": 3, "root": root.path, "local_only": true]) }
    func observe(_ model: RecordingApplication, hotkey: HotkeyConfiguration) {
        let state: String
        switch model.state {
        case .ready: state = "ready"
        case .requestingMicrophone: state = "requestingMicrophone"
        case .recording(let id, _):
            state = "recording"
            if currentRecording == nil {
                recordingIndex += 1; currentRecording = id
                trace.record("recording_start", fields: ["history_id": id.uuidString, "recording_index": recordingIndex,
                    "main_active": model.mainRequestBudget.activeCount, "coach_active": model.coachScheduler?.inFlightCount ?? 0,
                    "main_limit": model.mainRequestBudget.limit, "coach_limit": model.coachScheduler?.configuration.concurrency ?? 0])
            } else if currentRecording != id { trace.fail("ambiguous_recording_identity") }
        }
        if state == "ready", let id = currentRecording {
            trace.record("recording_end", fields: ["history_id": id.uuidString, "recording_index": recordingIndex]); currentRecording = nil
        }
        trace.record("state", fields: ["state": state, "main_active": model.mainRequestBudget.activeCount,
            "coach_active": model.coachScheduler?.inFlightCount ?? 0, "main_limit": model.mainRequestBudget.limit,
            "coach_limit": model.coachScheduler?.configuration.concurrency ?? 0])
        checkpointIfRequested(model, hotkey: hotkey)
    }
    private func checkpointIfRequested(_ model: RecordingApplication, hotkey: HotkeyConfiguration) {
        guard !commandInProgress, model.state == .ready, model.mainRequestBudget.activeCount == 0,
              model.coachScheduler?.inFlightCount == 0, model.coachScheduler?.pendingCount == 0 else { return }
        let path = root.appendingPathComponent("commands/checkpoint.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let data = try Data(contentsOf: path)
            guard data.count <= 4_096, let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  command["schema_version"] as? Int == 1, command["run_id"] as? String == runID,
                  let name = command["checkpoint_id"] as? String, let id = UUID(uuidString: name) else { throw NativeError.configuration }
            guard !consumedCommands.contains(id) else { return }
            consumedCommands.insert(id)
            let entries = try model.history(), queue = try model.queue()
            guard queue.isEmpty, entries.allSatisfy({ $0.disposition != .awaitingProcessing &&
                !["waitingForSlot", "waitingForConfiguration", "waitingForNetwork", "waitingForBackoff", "inFlight"].contains($0.polish?.status.rawValue ?? "") &&
                !["queued", "waitingForConfiguration", "waitingForNetwork", "waitingForBackoff", "waitingForResume", "inFlight"].contains($0.coach?.status.rawValue ?? "") }) else { trace.fail("checkpoint_not_drained"); return }
            commandInProgress = true
            let exportsRoot = root.appendingPathComponent("exports"), checkpointsRoot = root.appendingPathComponent("checkpoints")
            try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpointsRoot, withIntermediateDirectories: true)
            var exports: [[String: Any]] = []
            for entry in entries {
                let output = exportsRoot.appendingPathComponent("\(entry.id).wav")
                try model.exportAudio(entry.id, to: output)
                let wave = try Data(contentsOf: output)
                exports.append(["history_id": entry.id.uuidString, "path": "exports/\(entry.id).wav", "frame_count": entry.frameCount,
                    "rate": entry.sampleRate, "pcm_sha256": SHA256.hash(data: wave.dropFirst(44)).map { String(format: "%02x", $0) }.joined(),
                    "wav_sha256": SHA256.hash(data: wave).map { String(format: "%02x", $0) }.joined()])
            }
            let asrConfig = try ServiceSettings(file: settings.appendingPathComponent("services.json")).load()
            let polishConfig = try PolishSettings(file: settings.appendingPathComponent("polish.json")).load()
            let coachConfig = try CoachSettings(file: settings.appendingPathComponent("coach.json")).load()
            let resources = try ResourceSettings(file: settings.appendingPathComponent("resources.json")).load()
            var config: [String: Any] = ["maximum_pending_segments": resources.maximumPendingSegments,
                "maximum_pending_duration": resources.maximumPendingDuration, "maximum_pending_audio_bytes": resources.maximumPendingAudioBytes,
                "maximum_recording_duration": resources.maximumRecordingDuration, "maximum_local_bytes": resources.maximumLocalBytes,
                "automatic_sending_window": resources.automaticSendingWindow]
            config.merge(["main_limit": model.mainRequestBudget.limit, "coach_limit": model.coachScheduler?.configuration.concurrency ?? 0,
                "asr_timeout": asrConfig.transcriptionTimeout, "polish_timeout": polishConfig.timeout, "coach_timeout": coachConfig.timeout,
                "binding": try JSONSerialization.jsonObject(with: JSONEncoder().encode(hotkey.binding)),
                "gesture": hotkey.gesture.rawValue, "input_mode": coachConfig.inputMode.rawValue]) { _, new in new }
            let entryObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))
            let object: [String: Any] = ["checkpoint_id": id.uuidString, "entries": entryObjects, "queue": [],
                "config": config, "exports": exports]
            trace.record("checkpoint", fields: object, snapshot: checkpointsRoot.appendingPathComponent("\(id).json"))
            commandInProgress = false
        } catch { commandInProgress = false; trace.fail("checkpoint_failed") }
    }
    enum NativeError: Error { case configuration }
}

final class NativeMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "unused-native-memory")! }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
    override func data(forKey defaultName: String) -> Data? { lock.withLock { values[defaultName] as? Data } }
    override func bool(forKey defaultName: String) -> Bool { lock.withLock { values[defaultName] as? Bool ?? false } }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func set(_ value: Bool, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func removeObject(forKey defaultName: String) { _ = lock.withLock { values.removeValue(forKey: defaultName) } }
    override func synchronize() -> Bool { true }
}
@MainActor
final class NativeServiceCredentials: ServiceCredentialStoring {
    private var values: [UUID: String] = [:]
    func key(for serviceID: UUID) throws -> String? { values[serviceID] }
    func saveKey(_ key: String?, for serviceID: UUID) throws {
        guard key == nil || key == "native-acceptance-fake-key" else { throw TranscriptionFailure.credentialsUnavailable }
        values[serviceID] = key
    }
}
struct NativeDataKey: LocalDataKeyProviding {
    func loadKey(createIfMissing: Bool) throws -> Data { Data(repeating: 0x9A, count: 32) }
}

final class NativeAppTrace: @unchecked Sendable {
    private let file: FileHandle
    private let runID: String
    private let queue = DispatchQueue(label: "queued-dictation.native-app-trace", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var sequence = 0
    private var failureScheduled = false
    private let clock: () -> UInt64 = {
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let product = mach_absolute_time().multipliedFullWidth(by: UInt64(timebase.numer))
        guard timebase.denom != 0, product.high < UInt64(timebase.denom) else { return 0 }
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }
    init(root: URL, runID: String) throws {
        self.runID = runID
        let path = root.appendingPathComponent("native-app.jsonl")
        guard !FileManager.default.fileExists(atPath: path.path), FileManager.default.createFile(atPath: path.path, contents: nil) else { throw NativeAcceptanceEnvironment.NativeError.configuration }
        file = try FileHandle(forWritingTo: path)
    }
    func record(_ event: String, fields: [String: Any], snapshot: URL? = nil) {
        let ns = clock()
        guard ns > 0 else { fail("app_clock_invalid"); return }
        lock.lock()
        guard !failureScheduled, pending < 512 else { lock.unlock(); fail("app_trace_overflow"); return }
        pending += 1; sequence += 1
        var object = fields
        object.merge(["schema_version": 1, "run_id": runID, "event": event, "sequence": sequence,
            "pid": ProcessInfo.processInfo.processIdentifier, "monotonic_ns": ns]) { _, new in new }
        let payload = NativeAppPayload(object: object)
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            do {
                let data = try JSONSerialization.data(withJSONObject: payload.object, options: [.sortedKeys])
                try file.write(contentsOf: data + Data("\n".utf8))
                if let snapshot { try data.write(to: snapshot, options: .atomic) }
            } catch { fail("app_trace_io_failure") }
        }
        lock.unlock()
    }
    func fail(_ reason: String) {
        lock.lock()
        guard !failureScheduled else { lock.unlock(); return }
        failureScheduled = true; sequence += 1
        let number = sequence
        queue.async { [self] in
            let object: [String: Any] = ["schema_version": 1, "run_id": runID, "event": "trace_failure", "sequence": number,
                "pid": ProcessInfo.processInfo.processIdentifier, "monotonic_ns": clock(), "reason": reason]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                try? file.write(contentsOf: data + Data("\n".utf8))
            }
            FileHandle.standardError.write(Data("NATIVE_ACCEPTANCE_FAILURE \(reason)\n".utf8))
        }
        lock.unlock()
    }
}
private struct NativeAppPayload: @unchecked Sendable { let object: [String: Any] }

final class NativeOrigin: @unchecked Sendable {
    private let lock = NSLock(); private var value: URL?
    func withLock<T>(_ body: (inout URL?) -> T) -> T { lock.withLock { body(&value) } }
}
final class NativeLocalURLProtocol: URLProtocol, @unchecked Sendable {
    static let origin = NativeOrigin()
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NativeLocalURLProtocol.self]
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return config
    }
    override class func canInit(with request: URLRequest) -> Bool {
        !origin.withLock { origin in
            guard let origin, let url = request.url else { return false }
            return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port &&
                url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
                ["/v1/audio/transcriptions", "/v1/chat/completions"].contains(url.path)
        }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}
#endif
