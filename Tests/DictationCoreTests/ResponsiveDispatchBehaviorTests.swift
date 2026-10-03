import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DictationCore

@MainActor
@Suite(.serialized)
struct ResponsiveDispatchBehaviorTests {
    @Test
    func preparedRequestsUseTheLatestCredentialsModelAndOneActualHTTPSlotAfterTheLimitIsReduced() async throws {
        let f = try ResponsiveFixture()
        let latestServer = try ResponsiveHTTPServer()
        defer { latestServer.stop(); f.remove() }
        for _ in 0..<3 { _ = try await f.record() }
        try f.configure(model: "before-prepare")
        f.app.configurationChanged()
        #expect(f.app.mainRequestBudget.activeCount == 3)
        #expect(try f.app.history().allSatisfy { $0.transcription?.status != .inFlight })
        try f.app.updateProcessingConfiguration(.init(maximumConcurrentMainRequests: 1))
        let latestService = ModelService(id: f.service.id, name: "新派发端点", baseURL: latestServer.baseURL, authentication: .bearerToken)
        try f.services.save(.init(services: [latestService], transcription: .init(serviceID: f.service.id, model: "latest-model")))
        try f.credentials.saveKey("latest-fake-key", for: f.service.id)
        f.timing.advance(to: 1_000)
        var peakSent = 0
        f.app.onChange = { peakSent = max(peakSent, (try? f.app.history().filter { $0.transcription?.status == .inFlight }.count) ?? 0) }
        for index in 0..<3 {
            try await responsiveWait { latestServer.requests.count > index }
            let request = latestServer.requests[index]
            #expect(latestServer.requests.count == index + 1 && f.server.requests.isEmpty)
            #expect(f.app.mainRequestBudget.activeCount == 1)
            #expect(request.model == "latest-model" && request.authorization == "Bearer latest-fake-key")
            #expect(request.waveBytes == 8_236 && request.frames == 4_096)
            latestServer.reply(request, status: 503)
        }
        try await responsiveWait { f.app.mainRequestBudget.activeCount == 0 }
        #expect(peakSent == 1 && latestServer.requests.count == 3 && f.server.requests.isEmpty)
        #expect(try f.app.history().allSatisfy { $0.transcription?.failure == .serviceUnavailable })
        #expect(try f.app.reservedStorageBytes == 0)
    }

    @Test
    func aPreparedRequestWaitsOfflineWithoutARequestDeadlineAndPausesUntilExplicitWindowResume() async throws {
        let f = try ResponsiveFixture()
        defer { f.remove() }
        try f.resources.save(.init(automaticSendingWindow: 3_600))
        let id = try await f.record()
        try f.configure()
        f.app.configurationChanged()
        f.network.available = false
        f.timing.advance(to: 1_000)
        try await responsiveWait { (try? f.app.history().first?.transcription?.status) == .waitingForNetwork }
        #expect(f.server.requests.isEmpty && f.app.mainRequestBudget.activeCount == 0)
        #expect(try f.app.history().first?.transcription?.failure != .timedOut)
        f.clock.date.addTimeInterval(3_601)
        f.network.available = true
        f.app.configurationChanged()
        #expect(try f.app.history().first?.queueStage == .waitingForResume)
        try f.resources.save(.init(automaticSendingWindow: 7_200))
        f.app.configurationChanged()
        #expect(f.server.requests.isEmpty && f.app.mainRequestBudget.activeCount == 0)
        try f.app.resumePendingProcessing(id)
        try await responsiveWait { f.server.requests.count == 1 }
        f.server.reply(f.server.requests[0], status: 503)
        try await responsiveWait { f.app.mainRequestBudget.activeCount == 0 }
        #expect(try f.app.history().first?.transcription?.failure == .serviceUnavailable)
        #expect(try f.app.reservedStorageBytes == 0)
    }

    @Test(arguments: ["cancel", "delete", "stop", "prepare"])
    func unsentPreparationCannotReturnAfterInvalidationAndOrdinaryStopAllowsNewExplicitWork(_ action: String) async throws {
        let f = try ResponsiveFixture()
        defer { f.remove() }
        let id = try await f.record()
        try f.configure()
        f.app.configurationChanged()
        let oldAttempt = try #require(f.app.history().first?.transcription?.attemptID)
        #expect(try f.app.history().first?.transcription?.status != .inFlight)
        switch action {
        case "cancel": try f.app.cancelRecordedSegment(id)
        case "delete": try f.app.deleteHistory(id)
        case "stop": f.app.stopProcessing()
        default: f.app.prepareForTermination()
        }
        #expect(f.app.mainRequestBudget.activeCount == 0)
        #expect(try f.app.reservedStorageBytes == 0)
        if action == "prepare" {
            #expect(throws: DictationError.applicationTerminating) { try f.app.retryTranscription(id) }
            #expect(!(await f.app.startRecording()))
        } else {
            if action == "stop" { try f.app.retryTranscription(id) }
            else { _ = try await f.record() }
            try await responsiveWait { f.server.requests.count == 1 }
            #expect(try f.app.history().filter { $0.transcription?.status == .inFlight }.allSatisfy { $0.transcription?.attemptID != oldAttempt })
            f.server.reply(f.server.requests[0], status: 503)
            try await responsiveWait { f.app.mainRequestBudget.activeCount == 0 }
        }
        for _ in 0..<20 { await Task.yield() }
        f.app.configurationChanged()
        #expect(f.server.requests.count == (action == "prepare" ? 0 : 1))
        #expect(try f.app.reservedStorageBytes == 0)
        if action == "delete" { #expect(try f.app.history().allSatisfy { $0.id != id }) }
        if action == "cancel" { #expect(try f.app.history().first { $0.id == id }?.disposition == .cancelled) }
    }

    @Test
    func aTriggeredRecordingStartsBeforeAllDefaultASRRequestsAreSentWhileAllThreeCompleteWavesStillArrive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("responsive-dispatch-\(UUID())")
        let source = ResponsiveCapture(), server = try ResponsiveHTTPServer(), credentials = TestServiceCredentials()
        let settings = ServiceSettings(file: root.appendingPathComponent("services.json"))
        try settings.save(ModelConfiguration())
        let service = ModelService(name: "合成 PCM 本机服务", baseURL: server.baseURL, authentication: .bearerToken)
        try credentials.saveKey("responsive-fake-key", for: service.id)
        let probe = ResponsiveCaptureProbe()
        var action: (@MainActor @Sendable () async -> Bool)?
        var armed = false
        let app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            diskSpace: { _ in
                if armed {
                    armed = false
                    if let action { try probe.enqueue(action) }
                }
                return 100 * 1_024 * 1_024 * 1_024
            }, transcription: .init(settings: settings, credentials: credentials, delivery: ControlledTextDelivery()),
            resourceSettings: ResourceSettings(file: root.appendingPathComponent("resources.json")))
        action = { await app.startRecording() }
        defer {
            app.onChange = nil; app.stopProcessing(); source.stop(); server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let samples = (0..<4_096).map { Int16($0 % 1_999 - 999).littleEndian }
        let bytes = samples.withUnsafeBytes { Data($0) }
        var ids: [UUID] = []
        for _ in 0..<3 {
            #expect(await app.startRecording())
            guard case .recording(let id, _) = app.state else { throw ResponsiveTestError.recording }
            var remaining = 14_400_000
            while remaining > 0 {
                let frames = min(4_096, remaining)
                source.emit(PCMChunk(samples: Data(bytes.prefix(frames * 2)), sampleRate: 48_000))
                remaining -= frames
            }
            await app.finishRecording()
            ids.append(id)
        }
        #expect(try app.queueUsage().duration == 900)
        #expect(try app.queueUsage().audioBytes < 268_435_456)
        try await responsiveWait { (try? app.history().filter { $0.transcription?.status == .waitingForConfiguration }.count) == 3 }
        var sentAtNewCapture: Int?
        var peakSlots = 0
        source.onStart = { sentAtNewCapture = try? app.history().filter { $0.transcription?.status == .inFlight }.count }
        app.onChange = { peakSlots = max(peakSlots, app.mainRequestBudget.activeCount) }
        armed = true
        try settings.save(.init(services: [service], transcription: .init(serviceID: service.id, model: "responsive-asr")))
        app.configurationChanged()
        try await responsiveWait { probe.finished }
        #expect(probe.result)
        #expect((try #require(sentAtNewCapture)) < 3)
        try await responsiveWait { server.requests.count == 3 }
        #expect(peakSlots == 3)
        #expect(app.mainRequestBudget.activeCount == 3)
        for request in server.requests {
            #expect(request.path == "/audio/transcriptions")
            #expect(request.authorization == "Bearer responsive-fake-key")
            #expect(request.waveBytes == 28_800_044)
            #expect(request.frames == 14_400_000)
            #expect(request.waveSHA256 == "9a654d57622a47aba525d413ba48a363bb46e95a82a3606ff95371d51eaed647")
            server.reply(request, status: 503)
        }
        try await responsiveWait { app.mainRequestBudget.activeCount == 0 }
        #expect(try app.history().filter { ids.contains($0.id) }.allSatisfy { $0.transcription?.failure == .serviceUnavailable })
        #expect(server.requests.count == 3)
        await app.cancelCurrentRecording()
    }
}

@MainActor
private final class ResponsiveFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("responsive-controls-\(UUID())")
    let source = ResponsiveCapture()
    let server: ResponsiveHTTPServer
    let services: ServiceSettings
    let resources: ResourceSettings
    let credentials = TestServiceCredentials()
    let timing = ControlledRequestTiming()
    let clock = ResponsiveClock()
    let network = ResponsiveNetwork()
    let app: RecordingApplication
    let service: ModelService

    init() throws {
        server = try ResponsiveHTTPServer()
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        resources = ResourceSettings(file: root.appendingPathComponent("resources.json"))
        service = ModelService(name: "生成 PCM 控制", baseURL: server.baseURL, authentication: .bearerToken)
        let clock = self.clock
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            now: { clock.date }, diskSpace: { _ in 100 * 1_024 * 1_024 * 1_024 },
            transcription: .init(settings: services, credentials: credentials, delivery: ControlledTextDelivery(), timing: timing),
            resourceSettings: resources, network: network)
    }
    func configure(model: String = "controlled-asr", key: String = "controlled-fake-key") throws {
        try services.save(.init(services: [service], transcription: .init(serviceID: service.id, model: model)))
        try credentials.saveKey(key, for: service.id)
    }
    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw ResponsiveTestError.recording }
        let samples = (0..<4_096).map { Int16($0 % 1_999 - 999).littleEndian }
        source.emit(PCMChunk(samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 48_000))
        await app.finishRecording()
        return id
    }
    func remove() {
        app.onChange = nil; app.stopProcessing(); timing.cancelAll(); source.stop(); server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ResponsiveClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
private final class ResponsiveNetwork: NetworkAvailabilityProviding {
    var onChange: (() -> Void)?
    var available = true
    func isAvailable(for url: URL) -> Bool { available }
}

@MainActor
private final class ResponsiveCapture: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    var onStart: (() -> Void)?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        onStart?()
        let stream = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }
    func emit(_ chunk: PCMChunk) { continuation?.yield(chunk) }
    func stop() { continuation?.finish(); continuation = nil }
}

private final class ResponsiveCaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false, accepted = false
    var finished: Bool { lock.withLock { done } }
    var result: Bool { lock.withLock { accepted } }
    func enqueue(_ start: @escaping @MainActor @Sendable () async -> Bool) throws {
        let queued = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            Task { @MainActor [self] in
                let result = await start()
                lock.withLock { accepted = result; done = true }
            }
            queued.signal()
        }
        guard queued.wait(timeout: .now() + 1) == .success else { throw ResponsiveTestError.handshake }
    }
}

@MainActor
private func responsiveWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ResponsiveTestError.wait }
        await Task.yield()
    }
}

private enum ResponsiveTestError: Error { case recording, handshake, socket, wait }

private final class ResponsiveHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let path: String
        let authorization: String?
        let model: String?
        let waveBytes: Int
        let frames: UInt32
        let waveSHA256: String
    }
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
        guard descriptor >= 0 else { throw ResponsiveTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 8) == 0 else { close(descriptor); throw ResponsiveTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw ResponsiveTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "responsive-dispatch-loopback").async { [self] in
            defer { close(descriptor) }
            while !lock.withLock({ stopped }) {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }

    func reply(_ request: Request, status: Int) {
        let body = Data("{}".utf8)
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
            stopped = true; shutdown(listener, SHUT_RDWR)
            connections.values.forEach { shutdown($0, SHUT_RDWR) }
        }
    }

    private func receive(_ connection: Int32) {
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var headerEnd: Int?, expected = 0, path = "", authorization: String?
        while bytes.count <= 30_000_000 {
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
            if let end = headerEnd, expected > 0, bytes.count - end >= expected {
                let body = bytes.subdata(in: end..<end + expected)
                let modelStart = body.range(of: Data("name=\"model\"\r\n\r\n".utf8))?.upperBound
                let modelEnd = modelStart.flatMap { body.range(of: Data("\r\n".utf8), in: $0..<body.count)?.lowerBound }
                let model = modelStart.flatMap { start in modelEnd.flatMap { String(data: body.subdata(in: start..<$0), encoding: .utf8) } }
                guard let waveStart = body.range(of: Data("RIFF".utf8))?.lowerBound, waveStart + 44 <= body.count else { close(connection); return }
                let waveLength = body[waveStart + 4..<waveStart + 8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } + 8
                guard waveStart + Int(waveLength) <= body.count else { close(connection); return }
                let wave = body.subdata(in: waveStart..<waveStart + Int(waveLength))
                let frames = wave[40..<44].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } / 2
                let digest = SHA256.hash(data: wave).map { String(format: "%02x", $0) }.joined()
                let index = lock.withLock {
                    let index = captured.count
                    captured.append(Request(index: index, path: path, authorization: authorization, model: model, waveBytes: wave.count, frames: frames, waveSHA256: digest))
                    connections[index] = connection
                    if stopped { shutdown(connection, SHUT_RDWR) }
                    return index
                }
                bytes.removeAll(keepingCapacity: false)
                while recv(connection, &buffer, buffer.count, 0) > 0 {}
                lock.withLock { connections[index] = nil; close(connection) }
                return
            }
        }
        close(connection)
    }
}
