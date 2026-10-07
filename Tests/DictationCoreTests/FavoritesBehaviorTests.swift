import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite(.serialized)
struct FavoritesBehaviorTests {
    @Test
    func anAlteredFavoriteCannotBeReadExportedOrOverwrittenAndOtherFavoritesRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let first = favoriteSample(), other = favoriteSample()
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        try store.save(first)
        try store.save(other)
        let file = vault.appendingPathComponent("favorites/\(first.id).enc")
        var modified = try Data(contentsOf: file)
        modified[modified.count - 1] ^= 1
        try modified.write(to: file)
        let restarted = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        let output = root.appendingPathComponent("altered.txt")
        #expect(throws: FavoritesError.unreadableFavorites) { try restarted.entry(first.id) }
        #expect(throws: FavoritesError.unreadableFavorites) { try restarted.exportText(first.id, to: output) }
        #expect(throws: FavoritesError.unreadableFavorites) { try restarted.save(first) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: file) == modified)
        #expect(try restarted.entry(other.id) == other)
    }

    @Test(arguments: [false, true])
    func anExistingHistoryOrActiveRecordingNeverCreatesAReplacementDataKey(_ active: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let microphone = ControlledMicrophone()
        let app = RecordingApplication(source: microphone, historyDirectory: vault, keys: TestDataKey())
        #expect(await app.startRecording())
        microphone.emit(testAudio())
        try await waitUntil {
            if case .recording(_, let duration) = app.state { return duration == 0.5 }
            return false
        }
        if !active { await app.finishRecording() }
        let before = try savedFiles(vault)
        let missing = MissingDataKey()
        let favorites = FavoritesStore(vaultRoot: vault, keys: missing)
        #expect(throws: FavoritesError.dataKeyUnavailable) { try favorites.entries() }
        #expect(throws: FavoritesError.dataKeyUnavailable) { try favorites.save(favoriteSample()) }
        #expect(missing.creationRequests == 0)
        #expect(try savedFiles(vault) == before)
        if active { await app.cancelCurrentRecording() }
        app.stopProcessing()
    }

    @Test(arguments: [false, true])
    func missingOrWrongKeysKeepFavoritesAndCannotProducePlaintextDownloads(_ wrong: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let favorite = favoriteSample()
        try FavoritesStore(vaultRoot: vault, keys: TestDataKey()).save(favorite)
        let before = try savedFiles(vault)
        let missing = MissingDataKey()
        let key: any LocalDataKeyProviding = wrong ? WrongDataKey() : missing
        let blocked = FavoritesStore(vaultRoot: vault, keys: key)
        let expected: FavoritesError = wrong ? .unreadableFavorites : .dataKeyUnavailable
        let textURL = root.appendingPathComponent("blocked.txt"), jsonURL = root.appendingPathComponent("blocked.json")
        #expect(throws: expected) { try blocked.entries() }
        #expect(throws: expected) { try blocked.save(favorite) }
        #expect(throws: expected) { try blocked.delete(favorite.id) }
        #expect(throws: expected) { try blocked.exportText(favorite.id, to: textURL) }
        #expect(throws: expected) { try blocked.exportJSON(favorite.id, to: jsonURL) }
        #expect(missing.creationRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: textURL.path))
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(try savedFiles(vault) == before)
    }

    @Test
    func aSecondFavoriteUsesActualAllocatedBytesAndKeepsTheFirstWhenItsWriteIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        var limit: UInt64 = 2 * 1_024 * 1_024
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey(), maximumLocalBytes: { limit })
        let original = favoriteSample()
        try store.save(original)
        let before = try savedFiles(vault)
        let allocated = try store.bytesConsumed()
        #expect(allocated > 1_024)
        limit = try allocatedVaultBytes(vault) + 1_024 * 1_024 + allocated - 1
        var notifications = 0
        store.onChange = { notifications += 1 }
        #expect(throws: FavoritesError.localStorageLimit) { try store.save(favoriteSample()) }
        #expect(try savedFiles(vault) == before)
        #expect(try store.entries() == [original])
        #expect(try store.bytesConsumed() == allocated)
        #expect(notifications == 0)
    }

    @Test
    func newFavoritesRespectTheWholeVaultLatestQuotaAndActiveReservationsWithoutEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let microphone = ControlledMicrophone()
        let app = RecordingApplication(source: microphone, historyDirectory: vault, keys: TestDataKey())
        #expect(await app.startRecording())
        microphone.emit(testAudio())
        await app.finishRecording()
        let history = try app.history()
        var limit: UInt64 = 2 * 1_024 * 1_024, reserved: UInt64 = 0
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey(), maximumLocalBytes: { limit }, reservedBytes: { reserved })
        let favorite = favoriteSample()
        try store.save(favorite)
        let before = try savedFiles(vault)
        let favoritesBytes = try store.bytesConsumed()
        limit = favoritesBytes + 1_024 * 1_024 + 1_024
        #expect(throws: FavoritesError.localStorageLimit) { try store.save(favoriteSample()) }
        #expect(try savedFiles(vault) == before)
        limit = try allocatedVaultBytes(vault) + 1_024 * 1_024 + favoritesBytes * 2
        reserved = favoritesBytes * 2
        #expect(throws: FavoritesError.localStorageLimit) { try store.save(favoriteSample()) }
        #expect(try savedFiles(vault) == before)
        #expect(try app.history() == history)
        reserved = 0
        var notifications = 0
        store.onChange = { notifications += 1 }
        try store.save(favoriteSample())
        #expect(notifications == 1)
        limit = 1
        #expect(try store.entries().count == 2)
        try store.delete(favorite.id)
        #expect(notifications == 2)
        #expect(try store.entries().count == 1)
        #expect(try app.history() == history)
        app.stopProcessing()
    }

    @Test
    func aLowDiskBudgetKeepsExistingFavoritesReadableAndDeletable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        var available: UInt64 = 100 * 1_024 * 1_024
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey(), diskSpace: { _ in available })
        let favorite = favoriteSample()
        try store.save(favorite)
        let before = try savedFiles(vault)
        available = 1_024
        #expect(throws: FavoritesError.diskSpaceLow) { try store.save(favoriteSample()) }
        #expect(try savedFiles(vault) == before)
        #expect(try store.entries() == [favorite])
        try store.delete(favorite.id)
        #expect(try store.entries().isEmpty)
    }

    @Test
    func emptyFeedbackAndOversizedTextCannotCreateADataVault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let keys = MissingDataKey()
        let store = FavoritesStore(vaultRoot: vault, keys: keys)
        #expect(throws: FavoritesError.invalidSnapshot) {
            try store.save(FavoriteFeedback(rawText: "I go to work.", feedback: CoachFeedback(suggestions: [])))
        }
        #expect(throws: FavoritesError.invalidSnapshot) {
            try store.save(FavoriteFeedback(rawText: String(repeating: "x", count: 256 * 1_024 + 1),
                feedback: favoriteSample().feedback))
        }
        #expect(keys.creationRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: vault.path))
    }

    @Test
    func theSnapshotIsEncryptedAndExportsCannotOverwriteTheVaultThroughAnAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        let favorite = favoriteSample()
        try store.save(favorite)
        let before = try savedFiles(vault)
        #expect(before.count == 2)
        for data in before.values {
            #expect(data.starts(with: Data("QDENC1".utf8)))
            #expect(data.range(of: Data(favorite.rawText.utf8)) == nil)
            #expect(data.range(of: Data(favorite.feedback.suggestions[0].reason.utf8)) == nil)
        }
        let iterator = try #require(FileManager.default.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in iterator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
        for directory in [vault, vault.appendingPathComponent("favorites")] {
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o700)
        }
        let alias = root.appendingPathComponent("vault-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: vault)
        #expect(throws: FavoritesError.unsafeExportDestination) {
            try store.exportText(favorite.id, to: alias.appendingPathComponent("vault.enc"))
        }
        #expect(throws: FavoritesError.unsafeExportDestination) {
            try store.exportJSON(favorite.id, to: vault.appendingPathComponent("favorites/\(favorite.id).enc"))
        }
        #expect(try savedFiles(vault) == before)
    }

    @Test
    func aReadOnlyFavoritesDirectoryKeepsThePreviousEncryptedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = root.appendingPathComponent("vault")
        let directory = vault.appendingPathComponent("favorites")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        let original = favoriteSample()
        try store.save(original)
        let ciphertext = try savedFiles(vault)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let replacement = FavoriteFeedback(id: original.id, createdAt: original.createdAt, rawText: original.rawText,
            polishedText: "A changed polish.", feedback: original.feedback)
        #expect(throws: FavoritesError.storageUnavailable) { try store.save(replacement) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try savedFiles(vault) == ciphertext)
        #expect(try FavoritesStore(vaultRoot: vault, keys: TestDataKey()).entry(original.id) == original)
    }

    @Test(arguments: [false, true])
    func aFavoriteSurvivesDeletingOrExpiringItsRecordedSourceAndExportsActualTextAndFeedback(_ expires: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FavoritesLoopbackServer()
        defer { server.stop() }
        let vault = root.appendingPathComponent("vault")
        let services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        let credentials = TestServiceCredentials()
        let serviceID = UUID()
        try services.save(ModelConfiguration(services: [ModelService(id: serviceID, name: "本机行为服务",
            baseURL: server.baseURL, authentication: .none)],
            transcription: ModelRoleConfiguration(serviceID: serviceID, model: "fixture-asr")))
        let microphone = ControlledMicrophone()
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var now = recordedAt
        let app = RecordingApplication(source: microphone, historyDirectory: vault, keys: TestDataKey(),
            now: { now },
            transcription: TranscriptionDependencies(settings: services, credentials: credentials,
                networkConfiguration: .ephemeral, delivery: ControlledTextDelivery()))
        defer { app.stopProcessing() }
        #expect(await app.startRecording())
        microphone.emit(testAudio())
        await app.finishRecording()
        try await waitUntil { (try? app.history().first?.rawTranscription) == "I goes to work." }
        let source = try #require(app.history().first)
        now = recordedAt.addingTimeInterval(2 * 86_400)
        #expect(await app.startRecording())
        microphone.emit(testAudio())
        await app.finishRecording()
        try await waitUntil { (try? app.history().filter { $0.rawTranscription != nil }.count) == 2 }
        let other = try #require(app.history().first { $0.id != source.id })

        let settings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        try settings.save(CoachConfiguration(enabled: true,
            role: ModelRoleConfiguration(serviceID: serviceID, model: "fixture-coach")))
        let coach = CoachClient(settings: settings, services: services, credentials: credentials)
        var result: Result<CoachResult, CoachFailure>?
        let request = try coach.start(segmentID: source.id, rawText: try app.rawTranscription(source.id)) { result = $0 }
        defer { request.cancel() }
        try await waitUntil { result != nil }
        guard case .card(let feedback) = try #require(result).get() else {
            Issue.record("本机带教应返回完整反馈"); return
        }
        let favorite = FavoriteFeedback(createdAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            sourceSegmentID: source.id, rawText: try app.rawTranscription(source.id), polishedText: "I go to work.",
            feedback: feedback)
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        try store.save(favorite)
        var panel = CoachPanelState(enabled: true)
        let identity = CoachWorkIdentity(segmentID: source.id)
        let registered = panel.begin(identity, rawText: favorite.rawText)
        let presentation = panel.complete(identity, result: .card(feedback))
        #expect(registered)
        #expect(presentation == .presented)
        panel.removeCard(source.id)
        panel.setEnabled(false)
        #expect(try store.entries() == [favorite])
        if expires {
            let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: vault, keys: TestDataKey(),
                now: { recordedAt.addingTimeInterval(31 * 86_400) })
            #expect(try restarted.history().map(\.id) == [other.id])
        } else { try app.deleteHistory(source.id) }
        let remainingHistory = try app.history()
        #expect(remainingHistory.map(\.id) == [other.id])

        let reopened = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        #expect(try reopened.entries() == [favorite])
        let textURL = root.appendingPathComponent("favorite.txt")
        let jsonURL = root.appendingPathComponent("favorite.json")
        try reopened.exportText(favorite.id, to: textURL)
        try reopened.exportJSON(favorite.id, to: jsonURL)
        let text = try String(contentsOf: textURL, encoding: .utf8)
        #expect(text.contains("原始转写\nI goes to work."))
        #expect(text.contains("润色文本\nI go to work."))
        #expect(text.contains("原表达：I goes"))
        #expect(text.contains("改进：I go"))
        #expect(text.contains("原因：第一人称单数一般现在时使用 go。"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let exported = try decoder.decode(FavoriteFeedback.self, from: Data(contentsOf: jsonURL))
        #expect(exported == favorite)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "createdAt", "sourceSegmentID", "rawText", "polishedText", "feedback"])
        try reopened.delete(favorite.id)
        #expect(try FavoritesStore(vaultRoot: vault, keys: TestDataKey()).entries().isEmpty)
        #expect(try app.history() == remainingHistory)
    }
}

private func favoriteSample(id: UUID = UUID(), createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FavoriteFeedback {
    FavoriteFeedback(id: id, createdAt: createdAt, rawText: "I goes to work.",
        feedback: CoachFeedback(suggestions: [CoachSuggestion(category: .grammar, original: "I goes", improved: "I go",
            reason: "第一人称单数一般现在时使用 go。")]))
}

private func allocatedVaultBytes(_ vault: URL) throws -> UInt64 {
    let iterator = try #require(FileManager.default.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey]))
    var total: UInt64 = 0
    for case let url as URL in iterator {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        if info.isRegularFile == true {
            total += UInt64(max(try #require(info.fileSize), try #require(info.totalFileAllocatedSize)))
        }
    }
    return total
}

private final class FavoritesLoopbackServer: @unchecked Sendable {
    private let listener: Int32
    let baseURL: String
    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw FavoritesFixtureError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else { close(listener); throw FavoritesFixtureError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(listener); throw FavoritesFixtureError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "favorites-loopback-test").async { [self] in serve() }
    }
    func stop() { shutdown(listener, SHUT_RDWR) }
    private func serve() {
        defer { close(listener) }
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            respond(connection)
            close(connection)
        }
    }
    private func respond(_ connection: Int32) {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?, bodyLength = 0, path = ""
        while bytes.count < 2 * 1_024 * 1_024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
               let header = String(data: bytes.prefix(end), encoding: .utf8) {
                headerEnd = end
                let lines = header.components(separatedBy: "\r\n")
                path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
                bodyLength = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            }
            if let headerEnd, bytes.count - headerEnd >= bodyLength { break }
        }
        let body: Data
        if path.hasSuffix("audio/transcriptions") {
            body = Data(#"{"text":"I goes to work."}"#.utf8)
        } else {
            let content = #"{"kind":"card","suggestions":[{"category":"grammar","original":"I goes","improved":"I go","reason":"第一人称单数一般现在时使用 go。"}]}"#
            guard let encoded = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]) else { return }
            body = encoded
        }
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        response.withUnsafeBytes { pointer in
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

private enum FavoritesFixtureError: Error { case socket }
