import AppKit
import Foundation
import Darwin
import Testing
import DictationCore

@Suite(.serialized)
@MainActor
struct RuntimePreparationGuardTests {
    @Test(arguments: [false, true])
    func disabledExplicitRepolishRestoresTheExistingDeliveryProgress(_ initiallyManual: Bool) async throws {
        let f = try PreparationFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        f.delivery.acceptsTarget = !initiallyManual
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep the saved raw and document."])
        try await preparationWait { (try? f.app.history().first?.rawTranscription) != nil && f.app.mainRequestBudget.activeCount == 0 }
        let document = f.delivery.document.string
        let before = try #require(f.app.history().first)
        try f.app.repolish(id)
        let after = try #require(f.app.history().first)
        #expect(after.queueStage == (initiallyManual ? .awaitingManualDelivery : .completed))
        #expect(after.disposition == before.disposition && after.delivery == before.delivery)
        #expect(after.rawTranscription == before.rawTranscription && after.polishedText == before.polishedText)
        #expect(f.delivery.document.string == document)
        #expect(f.app.mainRequestBudget.activeCount == 0)
        #expect(try f.app.reservedStorageBytes == 0)
        #expect(f.server.requests.count == 1)
        try f.polishSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "preparation-polish")))
        f.app.configurationChanged()
        #expect(f.server.requests.count == 1 && f.app.mainRequestBudget.activeCount == 0)
    }

    @Test(arguments: [false, true])
    func aPersistedRawResultReleasesOnlyItsFinishedASRReservationBeforeTheNextRole(_ coachOnly: Bool) async throws {
        let f = try PreparationFixture(polishEnabled: !coachOnly, coachEnabled: coachOnly)
        defer { f.remove() }
        try f.resources.save(.init(maximumLocalBytes: 1_073_741_824))
        let id = try await f.record()
        let asr = try await f.request(.asr)
        let beforeUsage = try f.app.storageUsage()
        let padDir = f.history.appendingPathComponent("generated-quota")
        try FileManager.default.createDirectory(at: padDir, withIntermediateDirectories: true)
        let pad = padDir.appendingPathComponent("temporary-sparse.enc")
        try Data("QDENC1-generated-fixture".utf8).write(to: pad)
        let h = try FileHandle(forWritingTo: pad)
        let headroom: UInt64 = coachOnly ? 5_242_880 : 4_194_304
        try h.truncate(atOffset: 1_073_741_824 - beforeUsage - headroom)
        try h.close()
        f.app.invalidateStorageUsage()
        f.server.reply(asr, object: ["text": "I go yesterday."])
        try await preparationWait {
            let entry = try? f.app.history().first
            return coachOnly ? (entry?.coach?.status == .inFlight || entry?.coach?.failure == .storageFailure)
                : (entry?.polish?.status == .inFlight || entry?.polish?.failure == .storageFailure)
        }
        let entry = try #require(f.app.history().first)
        #expect(entry.rawTranscription == "I go yesterday.")
        #expect(entry.polish?.failure != .storageFailure)
        #expect(entry.coach?.failure != .storageFailure)
        let next = try await f.request(coachOnly ? .coach : .polish)
        #expect(next.userText == "I go yesterday.")
        f.server.replyChat(next, content: coachOnly ? "{\"kind\":\"no_card\"}" : "I went yesterday.")
        try await preparationWait { f.app.mainRequestBudget.activeCount == 0 && f.app.coachScheduler?.inFlightCount == 0 }
        #expect(f.server.requests.count == 2)
        #expect(try f.app.reservedStorageBytes == 0)
        #expect(try f.app.history().first { $0.id == id }?.disposition == .completed)
    }

    @Test(arguments: [false, true])
    func aNewExplicitHistoricalRepolishAfterRestartDoesNotInheritThePriorExpiredAttempt(_ initiallyManual: Bool) async throws {
        let f = try PreparationFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        f.delivery.acceptsTarget = !initiallyManual
        try f.resources.save(.init(automaticSendingWindow: 3_600))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Original historical raw."])
        try await preparationWait { (try? f.app.history().first?.rawTranscription) != nil && f.app.mainRequestBudget.activeCount == 0 }
        let originalDocument = f.delivery.document.string
        let originalDisposition = try #require(f.app.history().first?.disposition)
        try f.polishSettings.save(.init(enabled: true))
        try f.app.repolish(id)
        let oldAttempt = try #require(f.app.history().first?.polish?.attemptID)
        f.clock.date.addTimeInterval(3_601)
        f.app.configurationChanged()
        #expect(try f.app.history().first?.queueStage == .waitingForResume)
        #expect(throws: DictationError.repolishUnavailable) { try f.app.repolish(id) }
        f.app.stopProcessing()
        try f.polishSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "preparation-polish-fresh")))
        let clock = f.clock
        let restarted = RecordingApplication(source: PreparationMicrophone(), historyDirectory: f.history, keys: TestDataKey(), now: { clock.date },
            transcription: .init(settings: f.services, credentials: f.credentials, delivery: f.delivery, timing: f.timing),
            polish: PolishClient(settings: f.polishSettings, services: f.services, credentials: f.credentials, timing: f.timing),
            resourceSettings: f.resources, network: PreparationNetwork())
        defer { restarted.stopProcessing() }
        try restarted.repolish(id)
        #expect(try restarted.history().first?.queueStage != .waitingForResume)
        #expect(try restarted.history().first?.polish?.attemptID != oldAttempt)
        let request = try await f.request(.polish)
        #expect(request.model == "preparation-polish-fresh" && request.userText == "Original historical raw.")
        f.server.replyChat(request, content: "Only a new history revision.")
        try await preparationWait { (try? restarted.currentText(id)) == "Only a new history revision." }
        #expect(try restarted.history().first?.disposition == originalDisposition)
        #expect(f.delivery.document.string == originalDocument)
        #expect(f.server.requests.filter { $0.role == .asr }.count == 1)
        #expect(f.server.requests.filter { $0.role == .polish }.count == 1)
    }
}

@MainActor
private final class PreparationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-preparation-\(UUID())")
    let source = PreparationMicrophone()
    let server: PreparationLoopbackServer
    let credentials = TestServiceCredentials()
    let services: ServiceSettings
    let polishSettings: PolishSettings
    let coachSettings: CoachSettings
    let resources: ResourceSettings
    let timing = ControlledRequestTiming()
    let clock = PreparationClock()
    let capacity = PreparationCapacity()
    let delivery = PreparationDocumentDelivery()
    let network = PreparationNetwork()
    let serviceID = UUID()
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }

    init(polishEnabled: Bool = true, coachEnabled: Bool = true, concurrency: Int = 3, targetDelivery: (any TextDelivering)? = nil) throws {
        server = try PreparationLoopbackServer()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        polishSettings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        coachSettings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        resources = ResourceSettings(file: root.appendingPathComponent("resources.json"))
        let service = ModelService(id: serviceID, name: "合成口述 loopback", baseURL: server.baseURL, authentication: .bearerToken)
        try services.save(ModelConfiguration(services: [service], transcription: .init(serviceID: serviceID, model: "preparation-asr")))
        try credentials.saveKey("preparation-fake-key", for: serviceID)
        try polishSettings.save(PolishConfiguration(enabled: polishEnabled, role: .init(serviceID: serviceID, model: "preparation-polish"), customPrompt: "完整润色提示词，仅整理本段。"))
        try coachSettings.save(CoachConfiguration(enabled: coachEnabled, role: .init(serviceID: serviceID, model: "preparation-coach"), customPrompt: "完整文本带教提示词，不评流利度。"))
        let clock = self.clock, capacity = self.capacity
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            now: { clock.date },
            diskSpace: { _ in capacity.onCheck?(); return capacity.bytes },
            transcription: TranscriptionDependencies(settings: services, credentials: credentials, delivery: targetDelivery ?? delivery, timing: timing),
            polish: PolishClient(settings: polishSettings, services: services, credentials: credentials, timing: timing),
            coach: CoachDependencies(settings: coachSettings, services: services, credentials: credentials, timing: timing),
            resourceSettings: resources, network: network)
        try app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency))
    }

    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw PreparationTestError.recording }
        source.emit(testAudio())
        await app.finishRecording()
        return id
    }

    func request(_ role: PreparationRole, raw: String? = nil, ordinal: Int = 0) async throws -> PreparationLoopbackServer.Request {
        try await preparationWait { self.server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }.count > ordinal }
        return server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }[ordinal]
    }

    func remove() {
        capacity.onCheck = nil; app.onChange = nil
        app.stopProcessing(); source.stop(); timing.cancelAll(); server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PreparationClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
private final class PreparationCapacity {
    var bytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
    var onCheck: (() -> Void)?
}

@MainActor
private final class PreparationMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { stream = $0 } }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}

@MainActor
private final class PreparationDocumentDelivery: TextDelivering {
    let document = NSTextView()
    var copied = "等待时用户新复制的内容"
    var onDeliver: (() -> Void)?
    var acceptsTarget = true
    private struct Snapshot { var text: String; var range: NSRange }
    private var targets: [UUID: Snapshot] = [:]
    func captureTarget() -> TextDeliveryTarget? {
        let target = TextDeliveryTarget()
        targets[target.id] = Snapshot(text: document.string, range: document.selectedRange())
        return target
    }
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard acceptsTarget, let before = targets[target.id], before.text == document.string,
              before.range == document.selectedRange() else { return .manual }
        onDeliver?()
        document.insertText(text, replacementRange: document.selectedRange())
        for (id, saved) in targets where saved.text == before.text && saved.range == before.range {
            targets[id] = Snapshot(text: document.string, range: document.selectedRange())
        }
        return .delivered
    }
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult {
        document.insertText(text, replacementRange: document.selectedRange())
        return .delivered
    }
    func releaseTarget(_ target: TextDeliveryTarget) { targets[target.id] = nil }
    func copy(_ text: String) { copied = text }

}

private enum PreparationRole { case asr, polish, coach }

private final class PreparationLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let path: String
        let authorization: String?
        let body: Data
        private var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var role: PreparationRole { path.hasSuffix("audio/transcriptions") ? .asr : model.contains("coach") ? .coach : .polish }
        var model: String { json?["model"] as? String ?? "" }
        var jsonKeys: Set<String> { Set(json?.keys.map { $0 } ?? []) }
        var userText: String? { (json?["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "user" }?["content"] as? String }
        var systemText: String? { (json?["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "system" }?["content"] as? String }
    }
    private let lock = NSLock()
    private let listener: Int32
    private var captured: [Request] = []
    private var connections: [Int: Int32] = [:]
    private var closed: Set<Int> = []
    private var stopped = false
    let baseURL: String
    var requests: [Request] { lock.withLock { captured } }
    func disconnected(_ request: Request) -> Bool { lock.withLock { closed.contains(request.index) } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw PreparationTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 32) == 0 else { close(descriptor); throw PreparationTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw PreparationTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "model-preparation-loopback").async { [self] in
            defer { close(descriptor) }
            while !lock.withLock({ stopped }) {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }

    func reply(_ request: Request, object: [String: Any], status: Int = 200, headers: [String: String] = [:]) {
        reply(request, body: try! JSONSerialization.data(withJSONObject: object), status: status, headers: headers)
    }
    func replyChat(_ request: Request, content: String, status: Int = 200) {
        reply(request, object: ["choices": [["message": ["content": content]]]], status: status)
    }
    func reply(_ request: Request, body: Data, status: Int = 200, headers: [String: String] = [:]) {
        let extraHeaders = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        let header = Data("HTTP/1.1 \(status) Controlled\r\n\(extraHeaders)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        lock.withLock {
            guard let connection = connections[request.index] else { return }
            (header + body).withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = send(connection, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { break }
                    sent += count
                }
            }
            shutdown(connection, SHUT_RDWR)
        }
    }
    func stop() {
        lock.withLock {
            stopped = true
            shutdown(listener, SHUT_RDWR)
            connections.values.forEach { shutdown($0, SHUT_RDWR) }
        }
    }

    private func receive(_ connection: Int32) {
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?, expected = 0, path = "", authorization: String?
        while bytes.count < 4 * 1_024 * 1_024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { close(connection); return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
               let header = String(data: bytes.prefix(end), encoding: .utf8) {
                headerEnd = end
                let lines = header.components(separatedBy: "\r\n")
                path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
                expected = lines.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst(14).trimmingCharacters(in: .whitespaces)) }
            }
            if let end = headerEnd, bytes.count - end >= expected {
                let index = lock.withLock {
                    let index = captured.count
                    captured.append(Request(index: index, path: path, authorization: authorization, body: Data(bytes.dropFirst(end).prefix(expected))))
                    connections[index] = connection
                    if stopped { shutdown(connection, SHUT_RDWR) }
                    return index
                }
                while recv(connection, &buffer, buffer.count, 0) > 0 {}
                lock.withLock { connections[index] = nil; closed.insert(index); close(connection) }
                return
            }
        }
        close(connection)
    }
}

private func preparationCard(original: String, improved: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["kind": "card", "suggestions": [["category": "grammar", "original": original, "improved": improved, "reason": "昨天发生的动作应使用过去式。"]]]), encoding: .utf8)!
}

@MainActor
private func preparationWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw PreparationTestError.wait }
        await Task.yield()
    }
}

private enum PreparationTestError: Error { case socket, recording, wait }

@MainActor
private final class PreparationNetwork: NetworkAvailabilityProviding {
    var onChange: (() -> Void)?
    private var available = true
    func isAvailable(for url: URL) -> Bool { available }
    func setAvailable(_ value: Bool) { available = value; onChange?() }
}
