import AppKit
import CryptoKit
import Foundation
import Darwin
import Testing
import DictationCore

@Suite(.serialized)
@MainActor
struct HistoryArtifactsBehaviorTests {
    @Test
    func actualProductsExportAndAValidatedFavoriteSurvivesHistoryClearAndFreshInstances() async throws {
        let f = try ArtifactFixture()
        defer { f.remove() }
        let id = try await f.record()
        #expect(try f.app.availableHistoryExports(id) == [.audio])
        do {
            try await f.app.exportHistoryItem(.polishedText, for: id, to: f.root.appendingPathComponent("missing.txt"))
            Issue.record("A missing product was exported.")
        } catch let error as HistoryExportError { #expect(error == .unavailableItem) }
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        f.server.replyChat(try await f.request(.polish), content: "I went yesterday.")
        f.server.replyChat(try await f.request(.coach), content: "{\"kind\":\"card\",\"suggestions\":[{\"category\":\"grammar\",\"original\":\"go\",\"improved\":\"went\",\"reason\":\"Use the past tense for yesterday.\"}]}")
        try await artifactWait { f.app.coachScheduler?.panelState.cards.count == 1 && (try? f.app.history().first?.disposition) == .completed }
        let card = try #require(f.app.coachScheduler?.panelState.cards.first)
        let favorite = try f.app.favoriteSnapshot(for: card)
        #expect(favorite.id == card.identity.attemptID)
        #expect(favorite.rawText == "I go yesterday." && favorite.polishedText == "I went yesterday.")
        #expect(try f.app.favoriteSnapshot(for: id).feedback == favorite.feedback)
        let wrongAttempt = CoachCard(identity: .init(segmentID: id), rawText: card.rawText, feedback: card.feedback)
        #expect(throws: FavoritesError.invalidSnapshot) { try f.app.favoriteSnapshot(for: wrongAttempt) }
        let wrongMode = CoachCard(identity: card.identity, rawText: card.rawText, feedback: card.feedback, inputMode: .originalAudio)
        #expect(throws: FavoritesError.invalidSnapshot) { try f.app.favoriteSnapshot(for: wrongMode) }
        let items = try f.app.availableHistoryExports(id)
        #expect(items == HistoryExportItem.allCases)
        let folder = f.root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items { try await f.app.exportHistoryItem(item, for: id, to: folder.appendingPathComponent(item.fileName)) }
        let archive = folder.appendingPathComponent("history.zip")
        try await f.app.exportHistoryZIP(id, to: archive)
        try artifactTool("/usr/bin/unzip", ["-t", archive.path])
        let extracted = folder.appendingPathComponent("extracted")
        try artifactTool("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: extracted.path).sorted() == items.map(\.fileName).sorted())
        for item in items {
            #expect(try Data(contentsOf: extracted.appendingPathComponent(item.fileName)) == Data(contentsOf: folder.appendingPathComponent(item.fileName)))
        }
        let wave = try Data(contentsOf: folder.appendingPathComponent("original.wav"))
        #expect(wave.dropFirst(44) == testAudio().samples)
        #expect(try String(contentsOf: folder.appendingPathComponent("transcription.txt"), encoding: .utf8) == favorite.rawText)
        #expect(try String(contentsOf: folder.appendingPathComponent("polished.txt"), encoding: .utf8) == favorite.polishedText)
        let before = try f.app.storageUsage()
        let favorites = FavoritesStore(vaultRoot: f.history, keys: TestDataKey(), reservedBytes: { try f.app.reservedStorageBytes })
        favorites.onChange = { f.app.invalidateStorageUsage() }
        try favorites.save(favorite)
        #expect(try f.app.storageUsage() > before)
        #expect(try savedFiles(f.history).values.allSatisfy { $0.starts(with: Data("QDENC1".utf8)) })
        #expect(await f.app.startRecording())
        f.source.emit(testAudio())
        try await artifactWait { if case .recording(_, let duration) = f.app.state { return duration > 0 }; return false }
        try f.app.clearHistory()
        #expect(try f.app.history().isEmpty)
        if case .recording = f.app.state {} else { Issue.record("Clearing committed history stopped the current capture.") }
        #expect(try favorites.entry(favorite.id) == favorite)
        await f.app.cancelCurrentRecording()
        let restarted = RecordingApplication(source: ArtifactMicrophone(), historyDirectory: f.history, keys: TestDataKey())
        #expect(try restarted.history().isEmpty)
        #expect(try FavoritesStore(vaultRoot: f.history, keys: TestDataKey()).entry(favorite.id) == favorite)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(f.server.requests.count == 3)
    }

    @Test(arguments: HistoryRetentionPeriod.allCases)
    func theExplicitRetentionSourceIsReadAtTheExactBoundaryWithoutTouchingFavorites(_ period: HistoryRetentionPeriod) async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        try f.retention.save(period)
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "A completed history record."])
        f.server.replyChat(try await f.request(.coach), content: "{\"kind\":\"no_card\"}")
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .succeeded }
        #expect(try f.app.availableHistoryExports(id) == [.audio, .rawTranscription, .coachResult])
        #expect(throws: FavoritesError.invalidSnapshot) { try f.app.favoriteSnapshot(for: id) }
        let json = f.root.appendingPathComponent("no-card.json")
        try await f.app.exportHistoryItem(.coachResult, for: id, to: json)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: String] == ["kind": "no_card"])
        let days = period == .forever ? 400 : period.rawValue
        f.clock.date.addTimeInterval(Double(days) * 86_400 - 1)
        #expect(try f.app.history().contains { $0.id == id })
        f.clock.date.addTimeInterval(1)
        #expect(try f.app.history().contains { $0.id == id } == (period == .forever))
    }

    @Test
    func corruptAudioDoesNotAffectMetadataAvailabilityAndCannotReplaceAnExistingExport() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        let id = try await f.record()
        let chunk = f.history.appendingPathComponent("history/\(id)/00000000.audio")
        var data = try Data(contentsOf: chunk); data[data.count - 1] ^= 0x01; try data.write(to: chunk)
        #expect(try f.app.availableHistoryExports(id) == [.audio])
        let destination = f.root.appendingPathComponent("keep.wav")
        try Data("Existing user download".utf8).write(to: destination)
        do { try await f.app.exportHistoryItem(.audio, for: id, to: destination); Issue.record("Corrupt audio exported.") }
        catch let error as DictationError { #expect(error == .unreadableHistory) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Existing user download")
        let target = f.history.appendingPathComponent("bad.zip")
        do { try await f.app.exportHistoryZIP(id, to: target); Issue.record("Vault destination accepted.") }
        catch let error as DictationError { #expect(error == .unsafeExportDestination) }
    }

    @Test
    func invalidRetentionFailsClosedAndCancellingAnExportLeavesNoDownloadOrPlaintextInTheVault() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep this actual history."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        f.clock.date.addTimeInterval(366 * 86_400)
        try Data("7.0000000000000001".utf8).write(to: f.root.appendingPathComponent("history-retention-custom.json"))
        #expect(throws: HistoryRetentionSettingsError.invalidPeriod) { try f.app.history() }
        #expect(try f.app.availableHistoryExports(id) == [.audio, .rawTranscription])
        let output = f.root.appendingPathComponent("cancelled.zip")
        let task = Task { try await f.app.exportHistoryZIP(id, to: output) }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled export committed.") } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try savedFiles(f.history).values.allSatisfy { $0.starts(with: Data("QDENC1".utf8)) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).allSatisfy { !$0.hasPrefix(".history-export-") })
    }

    @Test
    func aDeliveredMainResultWithUnfinishedCoachSurvivesDefaultRetention() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        try f.coachSettings.save(.init(enabled: true))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep the pending coach history."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        #expect(try f.app.history().first?.coach?.status == .waitingForConfiguration)
        f.clock.date.addTimeInterval(31 * 86_400)
        let preserved = try f.app.history().first { $0.id == id }
        #expect(preserved != nil)
        #expect(preserved?.rawTranscription == "Keep the pending coach history.")
    }
}

@MainActor
final class ArtifactFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-artifacts-\(UUID())")
    let source = ArtifactMicrophone()
    let server: ArtifactLoopbackServer
    let credentials = TestServiceCredentials()
    let services: ServiceSettings
    let polishSettings: PolishSettings
    let coachSettings: CoachSettings
    let resources: ResourceSettings
    let retention: HistoryRetentionSettings
    let timing = ControlledRequestTiming()
    let clock = ArtifactClock()
    let capacity = ArtifactCapacity()
    let delivery = ArtifactDocumentDelivery()
    let network = ArtifactNetwork()
    let serviceID = UUID()
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }

    init(polishEnabled: Bool = true, coachEnabled: Bool = true, concurrency: Int = 3, targetDelivery: (any TextDelivering)? = nil) throws {
        server = try ArtifactLoopbackServer()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        polishSettings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        coachSettings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        resources = ResourceSettings(file: root.appendingPathComponent("resources.json"))
        retention = HistoryRetentionSettings(file: root.appendingPathComponent("history-retention-custom.json"))
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
            resourceSettings: resources, network: network, historyRetentionSettings: retention)
        try app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency))
    }

    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw ArtifactTestError.recording }
        source.emit(testAudio())
        await app.finishRecording()
        return id
    }

    func request(_ role: ArtifactRole, raw: String? = nil, ordinal: Int = 0) async throws -> ArtifactLoopbackServer.Request {
        try await artifactWait { self.server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }.count > ordinal }
        return server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }[ordinal]
    }

    func remove() {
        capacity.onCheck = nil; app.onChange = nil
        app.stopProcessing(); source.stop(); timing.cancelAll(); server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class ArtifactClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
final class ArtifactCapacity {
    var bytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
    var onCheck: (() -> Void)?
}

@MainActor
final class ArtifactMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { stream = $0 } }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}

@MainActor
final class ArtifactDocumentDelivery: TextDelivering {
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

enum ArtifactRole { case asr, polish, coach }

final class ArtifactLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let path: String
        let authorization: String?
        let body: Data
        private var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var role: ArtifactRole { path.hasSuffix("audio/transcriptions") ? .asr : model.contains("coach") ? .coach : .polish }
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
        guard descriptor >= 0 else { throw ArtifactTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 32) == 0 else { close(descriptor); throw ArtifactTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw ArtifactTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "history-artifacts-loopback").async { [self] in
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
func artifactWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ArtifactTestError.wait }
        await Task.yield()
    }
}

private func artifactTool(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ArtifactTestError.socket }
}

private enum ArtifactTestError: Error { case socket, recording, wait }

@MainActor
final class ArtifactNetwork: NetworkAvailabilityProviding {
    var onChange: (() -> Void)?
    private var available = true
    func isAvailable(for url: URL) -> Bool { available }
    func setAvailable(_ value: Bool) { available = value; onChange?() }
}
