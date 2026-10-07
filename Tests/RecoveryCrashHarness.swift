import AppKit
import CryptoKit
import Darwin
import Foundation

@MainActor
private final class CrashCapture: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { continuation = $0 } }
    func emit(_ ordinal: Int = 0) {
        let samples = Data((0..<4_000).flatMap { index in
            let sample = UInt16(truncatingIfNeeded: index * 13 + ordinal * 137)
            return [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
        })
        continuation?.yield(PCMChunk(samples: samples, sampleRate: 8_000))
    }
    func stop() { continuation?.finish() }
}

private final class CrashKeys: LocalDataKeyProviding {
    let mode: String
    var creations = 0
    init(_ mode: String) { self.mode = mode }
    func loadKey(createIfMissing: Bool) throws -> Data {
        if createIfMissing { creations += 1 }
        if mode == "missing" { throw DictationError.dataKeyUnavailable }
        return Data(repeating: mode == "wrong" ? 0x43 : 0x9A, count: 32)
    }
}

@MainActor
private final class CrashCredentials: ServiceCredentialStoring {
    let value: String
    init(_ value: String) { self.value = value }
    func key(for serviceID: UUID) throws -> String? { value }
    func saveKey(_ value: String?, for serviceID: UUID) throws {}
}

@MainActor
private final class CrashDocument: TextDelivering {
    let view = NSTextView()
    var capturedTargets = 0
    var copied: String?
    private var targets: Set<UUID> = []
    init(_ text: String) { view.string = text; view.setSelectedRange(NSRange(location: text.utf16.count, length: 0)) }
    func captureTarget() -> TextDeliveryTarget? {
        capturedTargets += 1
        let target = TextDeliveryTarget(); targets.insert(target.id); return target
    }
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard targets.contains(target.id) else { return .manual }
        return insertAtCurrentCursor(text)
    }
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult {
        view.insertText(text, replacementRange: view.selectedRange()); return .delivered
    }
    func releaseTarget(_ target: TextDeliveryTarget) { targets.remove(target.id) }
    func copy(_ text: String) { copied = text }
}

@main
private struct RecoveryCrashHarness {
    @MainActor
    static func main() async throws {
        let a = CommandLine.arguments
        guard a.count >= 4 else { exit(64) }
        let mode = a[1], root = URL(fileURLWithPath: a[2], isDirectory: true), endpoint = a[3]
        let selected = a.count > 4 ? a[4] : "none", flavor = a.count > 5 ? a[5] : "old"
        let action = a.count > 6 ? a[6] : "none", keyMode = a.count > 7 ? a[7] : "correct"
        let documentText = a.count > 8 ? String(data: Data(base64Encoded: a[8]) ?? Data(), encoding: .utf8) ?? "New window: " : "Before: "
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        let polish = PolishSettings(file: root.appendingPathComponent("polish.json"))
        let coach = CoachSettings(file: root.appendingPathComponent("coach.json"))
        let serviceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        if mode == "seed" || mode == "capture" || mode == "capture-empty" || mode == "capture-multi" || flavor == "latest" {
            let service = ModelService(id: serviceID, name: "Generated recovery loopback", baseURL: endpoint, authentication: .bearerToken)
            try services.save(ModelConfiguration(services: [service], transcription: .init(serviceID: serviceID, model: "\(flavor)-asr")))
            let mainOnly = selected == "deliveryUncertain" || selected == "deliveryPerformed" || selected == "polishQueued" || selected == "completed"
            try polish.save(.init(enabled: !mainOnly, role: .init(serviceID: serviceID, model: "\(flavor)-polish"), customPrompt: "\(flavor) complete polish prompt"))
            try coach.save(.init(enabled: !mainOnly, role: .init(serviceID: serviceID, model: "\(flavor)-coach"), customPrompt: "\(flavor) complete coach prompt"))
        }
        let source = CrashCapture(), keys = CrashKeys(keyMode), document = CrashDocument(documentText)
        let credentials = CrashCredentials("\(flavor)-synthetic-key")
        let vault = root.appendingPathComponent("vault")
        let audioOnly = mode == "order"
        if mode == "legacy-format" {
            let active = vault.appendingPathComponent("active")
            let folder = try FileManager.default.contentsOfDirectory(at: active, includingPropertiesForKeys: nil).first!
            let activeID = folder.lastPathComponent, path = folder.appendingPathComponent("draft.enc")
            var metadata = try JSONSerialization.jsonObject(with: decrypt(path, context: "\(activeID)/draft")) as! [String: Any]
            metadata["sampleRate"] = 0
            let data = try JSONSerialization.data(withJSONObject: metadata)
            let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: Data(repeating: 0x9A, count: 32)), authenticating: Data("\(activeID)/draft".utf8))
            try (Data("QDENC1".utf8) + sealed.combined!).write(to: path, options: .atomic)
            try FileManager.default.removeItem(at: vault.appendingPathComponent("recording-order.enc"))
            emit(["legacyFormat": true]); return
        }
        let app = RecordingApplication(source: source, historyDirectory: vault, keys: keys,
            transcription: audioOnly ? nil : TranscriptionDependencies(settings: services, credentials: credentials, delivery: document),
            polish: audioOnly ? nil : PolishClient(settings: polish, services: services, credentials: credentials),
            coach: audioOnly ? nil : CoachDependencies(settings: coach, services: services, credentials: credentials))
        var id: UUID?
        app.recoveryFault = { point in
            guard point.rawValue == selected else { return }
            emit(["stoppedAt": point.rawValue, "id": id?.uuidString ?? NSNull(), "document": document.view.string])
            raise(SIGSTOP)
        }
        if mode.hasPrefix("capture") || mode == "seed" || mode == "order" {
            guard await app.startRecording(), case .recording(let recordingID, _) = app.state else {
                emit(["start": false, "notice": app.notice ?? NSNull(), "keyCreations": keys.creations]); return
            }
            id = recordingID
            let count = mode == "capture-empty" ? 0 : mode == "capture-multi" ? 3 : 1
            for ordinal in 0..<count { source.emit(ordinal) }
            if count > 0 {
                try await wait {
                    if case .recording(_, let duration) = app.state { return duration == Double(count) * 0.5 }
                    return false
                }
            }
            if mode.hasPrefix("capture") {
                emit(["stoppedAt": mode, "id": recordingID.uuidString, "document": document.view.string])
                raise(SIGSTOP)
            }
            await app.finishRecording()
            if mode == "order" { try await snapshot(app, keys: keys, document: document, vault: vault, extra: ["newID": recordingID.uuidString]); return }
            if selected == "polishQueued" {
                try await wait { (try? app.history().first?.disposition) == .completed }
                try polish.save(.init(enabled: true))
                try app.repolish(recordingID)
            } else if selected == "completed" {
                try await wait { (try? app.history().first?.disposition) == .completed }
                emit(["stoppedAt": "completed", "id": recordingID.uuidString, "document": document.view.string]); raise(SIGSTOP)
            } else {
                emit(["recorded": recordingID.uuidString])
                while true { try await Task.sleep(for: .seconds(1)) }
            }
        }
        var extra: [String: Any] = [:]
        if keyMode != "correct" {
            extra["start"] = await app.startRecording()
        } else {
            app.configurationChanged()
            if action != "none", let first = try app.history().first {
                do {
                    switch action {
                    case "resume": try app.resumePendingProcessing(first.id)
                    case "retryASR": try app.retryTranscription(first.id)
                    case "repolish": try app.repolish(first.id)
                    case "retryCoach": try app.retryCoach(first.id)
                    case "insert": _ = try app.insertCurrentTextAtCurrentCursor(first.id)
                    case "copy": try app.copyCurrentText(first.id)
                    case "confirm": try app.confirmManuallyDelivered(first.id)
                    case "skip": try app.skipMainDelivery(first.id)
                    default: exit(64)
                    }
                } catch { extra["actionError"] = String(describing: error) }
                if ["resume", "retryASR", "repolish", "retryCoach"].contains(action), extra["actionError"] == nil {
                    try await wait {
                        guard let entry = try? app.history().first else { return false }
                        let mainDone = entry.rawTranscription != nil && !(entry.polish.map { [.waitingForSlot, .inFlight].contains($0.status) } ?? false)
                        let coachDone = !(entry.coach.map { [.queued, .inFlight].contains($0.status) } ?? false)
                        return mainDone && coachDone
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        try await snapshot(app, keys: keys, document: document, vault: vault, extra: extra)
        app.stopProcessing(); source.stop()
    }

    @MainActor
    static func snapshot(_ app: RecordingApplication, keys: CrashKeys, document: CrashDocument, vault: URL, extra: [String: Any]) async throws {
        var result = extra
        do {
            let history = try app.history()
            result["history"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history))
            result["queue"] = try app.queue().map { ["id": $0.id.uuidString, "stage": $0.stage.rawValue, "head": $0.isHead] as [String: Any] }
            result["recovery"] = try app.recoveryItems().map {
                ["id": $0.id.uuidString, "interruptedRecording": $0.interruptedRecording, "canResume": $0.canResumeUnsent,
                 "retryASR": $0.needsTranscriptionRetry, "retryPolish": $0.needsPolishRetry, "retryCoach": $0.needsCoachRetry, "uncertain": $0.deliveryUncertain] as [String: Any]
            }
            result["waves"] = try history.map { entry in
                let target = vault.deletingLastPathComponent().appendingPathComponent("verified-\(entry.id).wav")
                try app.exportAudio(entry.id, to: target)
                let data = try Data(contentsOf: target)
                return ["id": entry.id.uuidString, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        "pcm": data.dropFirst(44).base64EncodedString()] as [String: Any]
            }
        } catch { result["readError"] = String(describing: error) }
        result["document"] = document.view.string
        result["capturedTargets"] = document.capturedTargets
        result["cards"] = app.coachScheduler?.panelState.cards.count ?? 0
        result["keyCreations"] = keys.creations
        result["recoveryNotice"] = app.recoveryNotice ?? NSNull()
        emit(result)
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw HarnessFailure.wait }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func decrypt(_ path: URL, context: String) throws -> Data {
        let data = try Data(contentsOf: path)
        guard data.starts(with: Data("QDENC1".utf8)) else { throw HarnessFailure.cipher }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(6)), using: SymmetricKey(data: Data(repeating: 0x9A, count: 32)), authenticating: Data(context.utf8))
    }
    static func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    enum HarnessFailure: Error { case wait, cipher }
}
