import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DictationCore

@Suite(.serialized)
@MainActor
struct RuntimeResourceBehaviorTests {
    @Test(arguments: [RuntimeInvalidation.prepare, .cancel, .stop])
    func manualInsertionDoesNotWriteAfterItsSlotReleaseObserverInvalidatesTheWork(_ action: RuntimeInvalidation) async throws {
        let fixture = try RuntimeFixture(coachEnabled: false, concurrency: 1)
        defer { fixture.remove() }
        let first = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Old raw A."])
        let oldPolish = try await fixture.request(.polish)
        _ = try await fixture.record()
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 1)
        var invalidated = false
        fixture.app.onChange = {
            guard !invalidated else { return }
            invalidated = true
            try! action.apply(to: fixture.app, id: first)
        }
        do { _ = try fixture.app.insertRawTranscriptionAtCurrentCursor(first) }
        catch { #expect(error is DictationError) }
        fixture.app.onChange = nil
        #expect(invalidated)
        #expect(fixture.delivery.document.string.isEmpty)
        let after = try #require(fixture.app.history().first { $0.id == first })
        #expect(after.delivery != .delivered)
        #expect(after.rawTranscription == "Old raw A.")
        try await runtimeWait { fixture.server.disconnected(oldPolish) }
    }

    @Test(arguments: [false, true])
    func manualHistoricalRepolishNeedsExplicitResumeAfterExpiryEvenWhenTheWindowIsWidened(_ initiallyManual: Bool) async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.delivery.acceptsTarget = !initiallyManual
        try fixture.resources.save(ResourceConfiguration(automaticSendingWindow: 3_600))
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Window probe raw."])
        try await runtimeWait { (try? fixture.app.history().first?.rawTranscription) != nil && fixture.app.mainRequestBudget.activeCount == 0 }
        let originalDocument = fixture.delivery.document.string
        let originalDisposition = try #require(fixture.app.history().first?.disposition)
        try fixture.polishSettings.save(PolishConfiguration(enabled: true))
        try fixture.app.repolish(id)
        #expect(try fixture.app.history().first?.polish?.status == .waitingForConfiguration)
        let previousAnchor = try #require(fixture.app.history().first?.automaticSendingStartedAt)
        fixture.clock.date.addTimeInterval(3_601)
        fixture.app.configurationChanged()
        #expect(try fixture.app.history().first?.queueStage == .waitingForResume)
        try fixture.resources.save(ResourceConfiguration(automaticSendingWindow: 7_200))
        try fixture.polishSettings.save(PolishConfiguration(enabled: true, role: .init(serviceID: fixture.serviceID, model: "runtime-polish")))
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        #expect(try fixture.app.history().first?.queueStage == .waitingForResume)
        #expect(try fixture.app.history().first?.automaticSendingStartedAt == previousAnchor)
        try fixture.app.resumePendingProcessing(id)
        let sent = try await fixture.request(.polish)
        #expect(sent.userText == "Window probe raw.")
        fixture.server.replyChat(sent, content: "History revision.")
        try await runtimeWait { (try? fixture.app.currentText(id)) == "History revision." }
        #expect(try fixture.app.history().first?.disposition == originalDisposition)
        #expect(fixture.delivery.document.string == originalDocument)
        #expect(fixture.server.requests.filter { $0.role == .polish }.count == 1)
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 1)
    }
}

enum RuntimeInvalidation: Sendable {
    case prepare, cancel, stop
    @MainActor func apply(to app: RecordingApplication, id: UUID) throws {
        switch self {
        case .prepare: app.prepareForTermination()
        case .cancel: try app.cancelRecordedSegment(id)
        case .stop: app.stopProcessing()
        }
    }
}

@MainActor
private final class RuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-runtime-\(UUID())")
    let source = RuntimeMicrophone()
    let server: RuntimeLoopbackServer
    let credentials = TestServiceCredentials()
    let services: ServiceSettings
    let polishSettings: PolishSettings
    let coachSettings: CoachSettings
    let resources: ResourceSettings
    let timing = ControlledRequestTiming()
    let clock = RuntimeClock()
    let capacity = RuntimeCapacity()
    let delivery = RuntimeDocumentDelivery()
    let serviceID = UUID()
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }

    init(polishEnabled: Bool = true, coachEnabled: Bool = true, concurrency: Int = 3) throws {
        server = try RuntimeLoopbackServer()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        polishSettings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        coachSettings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        resources = ResourceSettings(file: root.appendingPathComponent("resources.json"))
        let service = ModelService(id: serviceID, name: "合成口述 loopback", baseURL: server.baseURL, authentication: .bearerToken)
        try services.save(ModelConfiguration(services: [service], transcription: .init(serviceID: serviceID, model: "runtime-asr")))
        try credentials.saveKey("runtime-fake-key", for: serviceID)
        try polishSettings.save(PolishConfiguration(enabled: polishEnabled, role: .init(serviceID: serviceID, model: "runtime-polish"), customPrompt: "完整润色提示词，仅整理本段。"))
        try coachSettings.save(CoachConfiguration(enabled: coachEnabled, role: .init(serviceID: serviceID, model: "runtime-coach"), customPrompt: "完整文本带教提示词，不评流利度。"))
        let clock = self.clock, capacity = self.capacity
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            now: { clock.date },
            diskSpace: { _ in capacity.onCheck?(); return capacity.bytes },
            transcription: TranscriptionDependencies(settings: services, credentials: credentials, delivery: delivery, timing: timing),
            polish: PolishClient(settings: polishSettings, services: services, credentials: credentials, timing: timing),
            coach: CoachDependencies(settings: coachSettings, services: services, credentials: credentials, timing: timing),
            resourceSettings: resources)
        try app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency))
    }

    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw RuntimeTestError.recording }
        source.emit(testAudio())
        await app.finishRecording()
        return id
    }

    func request(_ role: RuntimeRole, raw: String? = nil, ordinal: Int = 0) async throws -> RuntimeLoopbackServer.Request {
        try await runtimeWait { self.server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }.count > ordinal }
        return server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }[ordinal]
    }

    func remove() {
        capacity.onCheck = nil; app.onChange = nil
        app.stopProcessing(); source.stop(); timing.cancelAll(); server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class RuntimeClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
private final class RuntimeCapacity {
    var bytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
    var onCheck: (() -> Void)?
}

@MainActor
private final class RuntimeMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { stream = $0 } }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}

@MainActor
private final class RuntimeDocumentDelivery: TextDelivering {
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

private enum RuntimeRole { case asr, polish, coach }

private final class RuntimeLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let path: String
        let authorization: String?
        let body: Data
        private var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var role: RuntimeRole { path.hasSuffix("audio/transcriptions") ? .asr : model.contains("coach") ? .coach : .polish }
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
        guard descriptor >= 0 else { throw RuntimeTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 32) == 0 else { close(descriptor); throw RuntimeTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw RuntimeTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "model-runtime-loopback").async { [self] in
            defer { close(descriptor) }
            while !lock.withLock({ stopped }) {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }

    func reply(_ request: Request, object: [String: Any], status: Int = 200) {
        reply(request, body: try! JSONSerialization.data(withJSONObject: object), status: status)
    }
    func replyChat(_ request: Request, content: String, status: Int = 200) {
        reply(request, object: ["choices": [["message": ["content": content]]]], status: status)
    }
    func reply(_ request: Request, body: Data, status: Int = 200) {
        let header = Data("HTTP/1.1 \(status) Controlled\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
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

private func runtimeCard(original: String, improved: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["kind": "card", "suggestions": [["category": "grammar", "original": original, "improved": improved, "reason": "昨天发生的动作应使用过去式。"]]]), encoding: .utf8)!
}

@MainActor
private func runtimeWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw RuntimeTestError.wait }
        await Task.yield()
    }
}

private enum RuntimeTestError: Error { case socket, recording, wait }

