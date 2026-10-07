import AVFoundation
import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite(.serialized)
struct FavoriteAudioEvidenceBehaviorTests {
    @Test(arguments: [false, true])
    func audioEvidenceSurvivesSourceDeletionInFavoriteTextAndJSONWithOrWithoutPolish(_ polished: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FavoriteAudioEvidenceServer()
        defer { server.stop() }
        let vault = root.appendingPathComponent("vault")
        let services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        let serviceID = UUID(), credentials = TestServiceCredentials()
        try credentials.saveKey("favorite-audio-fake-key", for: serviceID)
        try services.save(ModelConfiguration(services: [ModelService(id: serviceID, name: "收藏音频依据测试",
            baseURL: server.baseURL, authentication: .bearerToken)],
            transcription: ModelRoleConfiguration(serviceID: serviceID, model: "favorite-asr")))
        let polishSettings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        try polishSettings.save(PolishConfiguration(enabled: polished,
            role: ModelRoleConfiguration(serviceID: serviceID, model: "favorite-polish")))
        let microphone = ControlledMicrophone()
        let app = RecordingApplication(source: microphone, historyDirectory: vault, keys: TestDataKey(),
            transcription: TranscriptionDependencies(settings: services, credentials: credentials,
                delivery: ControlledTextDelivery()),
            polish: PolishClient(settings: polishSettings, services: services, credentials: credentials))
        defer { app.stopProcessing() }
        #expect(await app.startRecording())
        let pcm = testAudio()
        microphone.emit(pcm)
        await app.finishRecording()
        try await waitUntil { (try? app.history().first?.disposition) == .completed }
        let source = try #require(app.history().first)
        #expect(source.rawTranscription == "I goes to work.")
        #expect(source.polishedText == (polished ? "I go to work." : nil))
        let waveURL = root.appendingPathComponent("source.wav")
        try app.exportAudio(source.id, to: waveURL)
        let wave = try Data(contentsOf: waveURL)
        let audioFile = try AVAudioFile(forReading: waveURL, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(audioFile.length == 4_000 && audioFile.processingFormat.sampleRate == 8_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4_000))
        try audioFile.read(into: buffer)
        let samples = try #require(buffer.int16ChannelData?.pointee)
        #expect(Data(bytes: samples, count: Int(buffer.frameLength) * 2) == pcm.samples)

        let settings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        try settings.save(CoachConfiguration(enabled: true,
            role: ModelRoleConfiguration(serviceID: serviceID, model: "favorite-coach"), inputMode: .originalAudio))
        let coach = CoachClient(settings: settings, services: services, credentials: credentials)
        var result: Result<CoachResult, CoachFailure>?
        let request = try coach.start(segmentID: source.id, rawText: try app.rawTranscription(source.id),
            originalAudio: wave) { result = $0 }
        defer { request.cancel() }
        try await waitUntil { result != nil }
        #expect(request.dispatch.audioUsed && request.dispatch.audioDuration == 0.5)
        guard case .card(let feedback) = try #require(result).get() else {
            Issue.record("合法音频带教应返回流利度和语法建议"); return
        }
        #expect(feedback.suggestions.map(\.category) == [.fluency, .grammar])
        #expect(feedback.suggestions[0].original.isEmpty)
        #expect(feedback.suggestions[0].audioEvidence == CoachAudioEvidence(startSeconds: 0.123456,
            endSeconds: 0.456789, observation: "I 与 goes 之间有一次停顿。"))
        let sent = try #require(server.requests.first { $0.path.hasSuffix("chat/completions")
            && (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["model"] as? String == "favorite-coach" })
        #expect(sent.authorization == "Bearer favorite-audio-fake-key")
        let payload = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "I goes to work.")
        let sentAudio = try #require(parts.last?["input_audio"] as? [String: String])
        #expect(sentAudio["format"] == "wav" && sentAudio["data"] == wave.base64EncodedString())
        #expect(server.requests.count == (polished ? 3 : 2))

        let favorite = FavoriteFeedback(createdAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            sourceSegmentID: source.id, rawText: try app.rawTranscription(source.id),
            polishedText: source.polishedText, feedback: feedback)
        try FavoritesStore(vaultRoot: vault, keys: TestDataKey()).save(favorite)
        try app.deleteHistory(source.id)
        try FileManager.default.removeItem(at: waveURL)
        #expect(try app.history().isEmpty)
        let reopened = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        #expect(try reopened.entry(favorite.id) == favorite)
        let textURL = root.appendingPathComponent("favorite.txt"), jsonURL = root.appendingPathComponent("favorite.json")
        try reopened.exportText(favorite.id, to: textURL)
        try reopened.exportJSON(favorite.id, to: jsonURL)
        let text = try String(contentsOf: textURL, encoding: .utf8)
        #expect(text == (try reopened.text(favorite.id)))
        #expect(text.contains("原始转写\nI goes to work."))
        #expect(text.contains("润色文本\nI go to work.") == polished)
        #expect(text.contains("""
            建议 1 · 流利度
            音频依据：0.123456–0.456789 秒
            观察：I 与 goes 之间有一次停顿。
            改进：把 I go 连起来说，在句末停顿。
            原因：短语中间停顿影响连贯性。
            """))
        #expect(text.contains("""
            建议 2 · 语法
            原表达：I goes
            改进：I go
            原因：第一人称使用 go。
            """))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(FavoriteFeedback.self, from: Data(contentsOf: jsonURL)) == favorite)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        #expect(Set(object.keys) == (polished
            ? ["id", "createdAt", "sourceSegmentID", "rawText", "polishedText", "feedback"]
            : ["id", "createdAt", "sourceSegmentID", "rawText", "feedback"]))
        let suggestions = try #require((object["feedback"] as? [String: Any])?["suggestions"] as? [[String: Any]])
        let evidence = try #require(suggestions[0]["audioEvidence"] as? [String: Any])
        #expect(Set(evidence.keys) == ["startSeconds", "endSeconds", "observation"])
        #expect(evidence["startSeconds"] as? Double == 0.123456 && evidence["endSeconds"] as? Double == 0.456789)
        #expect(evidence["observation"] as? String == "I 与 goes 之间有一次停顿。")
        let favoriteFiles = try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("favorites").path)
        #expect(favoriteFiles == ["\(favorite.id).enc"])
        let vaultFiles = try savedFiles(vault)
        #expect(!vaultFiles.keys.contains { $0.hasSuffix(".audio") || $0.hasSuffix(".wav") })
        #expect(vaultFiles.values.allSatisfy { $0.starts(with: Data("QDENC1".utf8)) })
    }

    @Test
    func legacyTextFavoritesKeepGrammarAndExpressionWithoutInventingAudioEvidenceOrPolish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacy = try decoder.decode(FavoriteFeedback.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000034","createdAt":1700000000.125,"rawText":"I goes to work. Make a party.","feedback":{"suggestions":[{"category":"grammar","original":"I goes","improved":"I go","reason":"第一人称使用 go。"},{"category":"expression","original":"Make a party","improved":"Have a party","reason":"聚会通常使用 have a party。"}]}}"#.utf8))
        let store = FavoritesStore(vaultRoot: root.appendingPathComponent("vault"), keys: TestDataKey())
        try store.save(legacy)
        let reopened = FavoritesStore(vaultRoot: store.vaultRoot, keys: TestDataKey())
        #expect(try reopened.entry(legacy.id) == legacy)
        let text = try reopened.text(legacy.id)
        #expect(text.contains("""
            建议 1 · 语法
            原表达：I goes
            改进：I go
            原因：第一人称使用 go。
            """))
        #expect(text.contains("""
            建议 2 · 表达
            原表达：Make a party
            改进：Have a party
            原因：聚会通常使用 have a party。
            """))
        #expect(!text.contains("音频依据") && !text.contains("观察：") && !text.contains("润色文本"))
    }
}

private final class FavoriteAudioEvidenceServer: @unchecked Sendable {
    struct Request: Sendable { let path: String; let authorization: String?; let body: Data }
    private let listener: Int32
    private let lock = NSLock()
    private var received: [Request] = []
    var requests: [Request] { lock.withLock { received } }
    let baseURL: String

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw FavoriteAudioFixtureError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { close(descriptor); throw FavoriteAudioFixtureError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(descriptor); throw FavoriteAudioFixtureError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "favorite-audio-evidence-loopback").async { [self] in
            defer { close(listener) }
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                respond(connection)
                close(connection)
            }
        }
    }

    func stop() { shutdown(listener, SHUT_RDWR) }

    private func respond(_ connection: Int32) {
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?, bodyLength = 0
        while bytes.count < 2 * 1_024 * 1_024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
               let header = String(data: bytes.prefix(end), encoding: .utf8) {
                headerEnd = end
                bodyLength = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            }
            if let headerEnd, bytes.count - headerEnd >= bodyLength { break }
        }
        guard let headerEnd, let header = String(data: bytes.prefix(headerEnd), encoding: .utf8) else { return }
        let lines = header.components(separatedBy: "\r\n")
        let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)) }
        let body = Data(bytes.dropFirst(headerEnd).prefix(bodyLength))
        lock.withLock { received.append(Request(path: path, authorization: authorization, body: body)) }
        let response: Data
        if path.hasSuffix("audio/transcriptions") { response = Data(#"{"text":"I goes to work."}"#.utf8) }
        else {
            let model = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String
            let content = model == "favorite-polish" ? "I go to work." : #"{"kind":"card","suggestions":[{"category":"fluency","improved":"把 I go 连起来说，在句末停顿。","reason":"短语中间停顿影响连贯性。","audioEvidence":{"startSeconds":0.123456,"endSeconds":0.456789,"observation":"I 与 goes 之间有一次停顿。"}},{"category":"grammar","original":"I goes","improved":"I go","reason":"第一人称使用 go。"}]}"#
            guard let encoded = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]) else { return }
            response = encoded
        }
        let packet = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n".utf8) + response
        packet.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < pointer.count {
                let count = send(connection, base.advanced(by: sent), pointer.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

private enum FavoriteAudioFixtureError: Error { case socket }
