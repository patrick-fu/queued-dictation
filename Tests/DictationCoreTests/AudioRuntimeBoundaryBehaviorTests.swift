import Darwin
import Foundation
import Testing
import DictationCore

@Suite(.serialized)
@MainActor
struct AudioRuntimeBoundaryBehaviorTests {
    @Test
    func aPreparedUnsentAudioRequestConsumesConfigurationChangedDuringResultReservation() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        let latest = try ArtifactLoopbackServer()
        defer { latest.stop(); f.remove() }
        try f.coachSettings.save(.init(enabled: true, inputMode: .originalAudio))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "This is the selected raw segment."])
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .waitingForConfiguration && f.app.mainRequestBudget.activeCount == 0 }
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "old-audio-coach"),
            concurrency: 3, customPrompt: "old audio prompt", inputMode: .originalAudio))
        var switched = false
        f.capacity.onCheck = {
            guard !switched else { return }
            switched = true
            f.capacity.onCheck = nil
            let service = ModelService(id: f.serviceID, name: "latest loopback", baseURL: latest.baseURL, authentication: .bearerToken)
            try! f.services.save(.init(services: [service], transcription: .init(serviceID: f.serviceID, model: "artifact-asr")))
            try! f.credentials.saveKey("latest-config-fake-key", for: f.serviceID)
            try! f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "latest-text-coach"),
                concurrency: 1, customPrompt: "latest text prompt", inputMode: .text))
            f.app.configurationChanged()
            print("PROBE_CONFIG_SWITCH oldHttp=\(f.server.requests.filter { $0.role == .coach }.count) latestHttp=\(latest.requests.count) selectedMode=\(f.app.coachScheduler?.configuration.inputMode.rawValue ?? "nil") selectedConcurrency=\(f.app.coachScheduler?.configuration.concurrency ?? -1)")
        }
        f.app.configurationChanged()
        #expect(f.app.coachScheduler?.inFlightCount == 1)
        #expect(f.server.requests.filter { $0.role == .coach }.isEmpty && latest.requests.isEmpty)
        try await artifactWait { f.server.requests.filter { $0.role == .coach }.count + latest.requests.count == 1 }
        #expect(switched)
        let oldRequests = f.server.requests.filter { $0.role == .coach }
        let received = try #require((oldRequests + latest.requests).first)
        let object = try #require(JSONSerialization.jsonObject(with: received.body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let user = messages.first { $0["role"] as? String == "user" }?["content"]
        let parts = user as? [[String: Any]]
        let audioPresent = parts?.contains { $0["type"] as? String == "input_audio" } ?? false
        let raw = user as? String ?? parts?.first?["text"] as? String
        print("PROBE_ACTUAL oldHttp=\(oldRequests.count) latestHttp=\(latest.requests.count) model=\(received.model) prompt=\(received.systemText ?? "nil") authorization=\(received.authorization ?? "nil") audioPresent=\(audioPresent) rawMatches=\(raw == "This is the selected raw segment.")")
        #expect(oldRequests.isEmpty)
        #expect(latest.requests.count == 1)
        #expect(received.model == "latest-text-coach")
        #expect(received.systemText == "latest text prompt")
        #expect(received.authorization == "Bearer latest-config-fake-key")
        #expect(raw == "This is the selected raw segment.")
        #expect(!audioPresent)
        #expect(try f.app.history().first { $0.id == id }?.coach?.dispatch?.audioUsed == false)
        if oldRequests.isEmpty { latest.replyChat(received, content: #"{"kind":"no_card"}"#) }
        else { f.server.replyChat(received, content: #"{"kind":"no_card"}"#) }
        try await artifactWait { f.app.coachScheduler?.inFlightCount == 0 }
        #expect(f.server.requests.filter { $0.role == .coach }.count + latest.requests.count == 1)
        #expect(try f.app.reservedStorageBytes == 0)
        print("PROBE_TERMINAL coachHttp=\(f.server.requests.filter { $0.role == .coach }.count + latest.requests.count) slots=\(f.app.coachScheduler?.inFlightCount ?? -1) reserve=\(try f.app.reservedStorageBytes)")
    }

    @Test(arguments: [false, true])
    func theSynchronousClientRechecksPreflightAndKeepsTheOriginalDeadline(_ changesBody: Bool) async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: false)
        let latest = try ArtifactLoopbackServer()
        defer { latest.stop(); f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep this synchronous raw segment."])
        try await artifactWait { f.app.mainRequestBudget.activeCount == 0 }
        let waveFile = f.root.appendingPathComponent("synthetic-original.wav")
        try f.app.exportAudio(id, to: waveFile)
        let wave = try Data(contentsOf: waveFile)
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "synchronous-coach"),
            customPrompt: "original synchronous prompt", inputMode: .originalAudio))
        let client = CoachClient(settings: f.coachSettings, services: f.services, credentials: f.credentials, timing: f.timing)
        let serviceID = UUID(), attemptID = UUID()
        var switched = false, result: Result<CoachResult, CoachFailure>?
        let request = try client.start(segmentID: id, attemptID: attemptID, rawText: "Keep this synchronous raw segment.",
            originalAudio: wave, willStart: { _ in
                guard !switched else { return }
                switched = true
                f.timing.advance(to: 4)
                try f.services.save(.init(services: [.init(id: serviceID, name: "latest synchronous loopback",
                    baseURL: latest.baseURL, authentication: .bearerToken)]))
                try f.credentials.saveKey("latest-synchronous-fake-key", for: serviceID)
                try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: serviceID,
                    model: changesBody ? "latest-synchronous-coach" : "synchronous-coach"), timeout: 6,
                    customPrompt: changesBody ? "latest synchronous prompt" : "original synchronous prompt",
                    inputMode: changesBody ? .text : .originalAudio))
            }, completion: { result = $0 })
        defer { request.cancel() }
        try await artifactWait { latest.requests.count + f.server.requests.filter { $0.role == .coach }.count == 1 }
        #expect(f.server.requests.filter { $0.role == .coach }.isEmpty)
        let received = try #require(latest.requests.first)
        #expect(received.authorization == "Bearer latest-synchronous-fake-key")
        #expect(received.model == (changesBody ? "latest-synchronous-coach" : "synchronous-coach"))
        #expect(received.systemText == (changesBody ? "latest synchronous prompt" : "original synchronous prompt"))
        #expect(request.identity == CoachWorkIdentity(segmentID: id, attemptID: attemptID))
        #expect(request.dispatch.serviceID == serviceID && request.dispatch.timeout == 6)
        #expect(request.dispatch.audioUsed == !changesBody && request.deadline == 6)
        f.timing.advance(to: 6)
        try await artifactWait { result != nil }
        #expect(result == .failure(.timedOut))
        #expect(latest.requests.count == 1)
    }

    @Test
    func failedWaitingStatePersistenceCannotKeepAnOrphanPreparationAndBlockTheNextAudioSegment() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        var readOnlyDirectory: URL?
        defer {
            if let readOnlyDirectory { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDirectory.path) }
            f.remove()
        }
        try f.coachSettings.save(.init(enabled: true, concurrency: 1, inputMode: .originalAudio))
        let first = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "The first generated audio waits."])
        try await artifactWait { (try? f.app.history().first { $0.id == first }?.coach?.status) == .waitingForConfiguration }
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "lifecycle-coach"), concurrency: 1, inputMode: .originalAudio))
        f.app.configurationChanged()
        #expect(f.app.coachScheduler?.inFlightCount == 1)
        f.network.setAvailable(false)
        try await artifactWait { (try? f.app.history().first { $0.id == first }?.coach?.status) == .waitingForNetwork }
        #expect(f.server.requests.filter { $0.role == .coach }.isEmpty)
        let directory = f.history.appendingPathComponent("history/\(first)")
        readOnlyDirectory = directory
        try f.credentials.saveKey(nil, for: f.serviceID)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        f.network.setAvailable(true)
        let failed = try #require(f.app.history().first { $0.id == first })
        #expect(failed.coach?.status == .failed && failed.coach?.failure == .storageFailure)
        #expect(f.app.coachScheduler?.pendingCount == 0 && f.app.coachScheduler?.inFlightCount == 0)
        print("ORPHAN_FAILED history=\(String(describing: failed.coach?.status))/\(String(describing: failed.coach?.failure)) pending=\(f.app.coachScheduler?.pendingCount ?? -1) occupied=\(f.app.coachScheduler?.inFlightCount ?? -1) http=\(f.server.requests.filter { $0.role == .coach }.count)")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try f.credentials.saveKey("restored-lifecycle-fake-key", for: f.serviceID)
        f.app.configurationChanged()
        let second = try await f.record()
        f.server.reply(try await f.request(.asr, ordinal: 1), object: ["text": "The second generated audio should dispatch."])
        try await artifactWait { (try? f.app.history().first { $0.id == second }?.coach?.status) == .queued }
        f.app.configurationChanged()
        let canAdvance = f.app.coachScheduler?.inFlightCount == 1 || !f.server.requests.filter { $0.role == .coach }.isEmpty
        print("ORPHAN_NEW_SEGMENT pending=\(f.app.coachScheduler?.pendingCount ?? -1) occupied=\(f.app.coachScheduler?.inFlightCount ?? -1) http=\(f.server.requests.filter { $0.role == .coach }.count) advanced=\(canAdvance)")
        #expect(canAdvance)
        if !canAdvance {
            try f.app.deleteHistory(first)
            print("ORPHAN_DELETE_CONTROL pending=\(f.app.coachScheduler?.pendingCount ?? -1) occupied=\(f.app.coachScheduler?.inFlightCount ?? -1)")
        }
        let request = try await f.request(.coach)
        #expect(request.authorization == "Bearer restored-lifecycle-fake-key")
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let parts = try #require(messages.first { $0["role"] as? String == "user" }?["content"] as? [[String: Any]])
        #expect(parts.first { $0["type"] as? String == "text" }?["text"] as? String == "The second generated audio should dispatch.")
        let input = try #require(parts.first { $0["type"] as? String == "input_audio" }?["input_audio"] as? [String: String])
        let encoded = try #require(input["data"])
        let wave = try #require(Data(base64Encoded: encoded))
        #expect(wave.count == 8_044 && wave.dropFirst(44) == testAudio().samples)
        f.server.replyChat(request, content: "{\"kind\":\"no_card\"}")
        try await artifactWait { (try? f.app.history().first { $0.id == second }?.coach?.status) == .succeeded }
        #expect(f.server.requests.filter { $0.role == .coach }.count == 1 && f.app.coachScheduler?.inFlightCount == 0)
        #expect(try f.app.reservedStorageBytes == 0)
        print("ORPHAN_FINAL actual_http=\(f.server.requests.filter { $0.role == .coach }.count) pending=\(f.app.coachScheduler?.pendingCount ?? -1) occupied=\(f.app.coachScheduler?.inFlightCount ?? -1) reserve=\(try f.app.reservedStorageBytes)")
    }

    @Test
    func cancellingAnUnsentWorkerForPauseCannotFailItsImmediatelyResumedWorker() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        let server = try AudioBoundaryLoopbackServer()
        defer { f.delivery.onDeliver = nil; server.stop(); f.remove() }
        try f.services.save(.init(services: [.init(id: f.serviceID, name: "300 秒合成音频本机端点",
            baseURL: server.baseURL, authentication: .bearerToken)],
            transcription: .init(serviceID: f.serviceID, model: "preparation-asr")))
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "pause-resume-coach"), concurrency: 1, inputMode: .originalAudio))
        #expect(await f.app.startRecording())
        guard case .recording(let id, _) = f.app.state else { Issue.record("capture rejected"); return }
        let samples = (0..<4_096).map { Int16($0 % 1_999 - 999).littleEndian }
        let bytes = samples.withUnsafeBytes { Data($0) }
        var remaining = 14_400_000
        while remaining > 0 {
            let count = min(4_096, remaining)
            f.source.emit(PCMChunk(samples: Data(bytes.prefix(count * 2)), sampleRate: 48_000))
            remaining -= count
        }
        await f.app.finishRecording()
        #expect(try f.app.history().first?.frameCount == 14_400_000)
        var paused = false, resumed = false, gate = true
        f.app.canDispatch = { _ in gate }
        f.delivery.onDeliver = {
            guard !paused else { return }
            let before = try? f.app.history().first { $0.id == id }
            #expect(f.app.coachScheduler?.inFlightCount == 1)
            #expect(server.requests.filter { $0.role == .coach }.isEmpty)
            gate = false
            f.app.configurationChanged()
            #expect((try? f.app.history().first { $0.id == id }?.coach?.status) == .waitingForResume)
            #expect(f.app.coachScheduler?.inFlightCount == 0)
            paused = true
            gate = true
            do { try f.app.resumePendingProcessing(id); resumed = true }
            catch { Issue.record("resume rejected: \(error)") }
            let after = try? f.app.history().first { $0.id == id }
            #expect(after?.coach?.identity == before?.coach?.identity)
            #expect(f.app.coachScheduler?.inFlightCount == 1)
            print("PAUSE_RESUME_HANDSHAKE paused=\(paused) resumed=\(resumed) same_identity=\(after?.coach?.identity == before?.coach?.identity) occupied=\(f.app.coachScheduler?.inFlightCount ?? -1) http=\(server.requests.filter { $0.role == .coach }.count)")
        }
        try await artifactWait { server.requests.contains { $0.role == .asr } }
        server.reply(try #require(server.requests.first { $0.role == .asr }),
            object: ["text": "Resume the same generated original audio."])
        try await artifactWait {
            let status = try? f.app.history().first { $0.id == id }?.coach?.status
            return !server.requests.filter { $0.role == .coach }.isEmpty || status == .failed || status == .timedOut
        }
        #expect(paused && resumed)
        let status = try f.app.history().first { $0.id == id }?.coach
        let requests = server.requests.filter { $0.role == .coach }
        print("PAUSE_RESUME_OUTCOME status=\(String(describing: status?.status)) failure=\(String(describing: status?.failure)) occupied=\(f.app.coachScheduler?.inFlightCount ?? -1) pending=\(f.app.coachScheduler?.pendingCount ?? -1) http=\(requests.count)")
        #expect(requests.count == 1)
        #expect(status?.failure == nil)
        if let request = requests.first {
            server.replyChat(request, content: "{\"kind\":\"no_card\"}")
            try await artifactWait { (try? f.app.history().first { $0.id == id }?.coach?.status) == .succeeded }
        }
        #expect(try f.app.reservedStorageBytes == 0)
    }
}

private final class AudioBoundaryLoopbackServer: @unchecked Sendable {
    typealias Request = ArtifactLoopbackServer.Request
    private let lock = NSLock()
    private let listener: Int32
    private var captured: [Request] = []
    private var connections: [Int: Int32] = [:]
    private var stopped = false
    let baseURL: String
    var requests: [Request] { lock.withLock { captured } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw AudioBoundaryTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 32) == 0 else { close(descriptor); throw AudioBoundaryTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw AudioBoundaryTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "audio-boundary-loopback").async { [self] in
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
        // 300 秒的合法 PCM/WAV 与其 base64 JSON 都必须完整到达，不能用 fixture 大小上限隐藏竞态。
        while bytes.count < 64 * 1_024 * 1_024 {
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
                lock.withLock { connections[index] = nil; close(connection) }
                return
            }
        }
        close(connection)
    }
}

private enum AudioBoundaryTestError: Error { case socket }
