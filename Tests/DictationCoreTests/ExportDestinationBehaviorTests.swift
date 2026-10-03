import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite(.serialized)
struct ExportDestinationBehaviorTests {
    @Test(arguments: [false, true])
    func historyDownloadRejectsASelectedFolderRedirectedIntoTheVaultDuringPreparation(redirect: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-destination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault"), downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: vault, keys: TestDataKey(),
            diskSpace: { _ in 100 * 1_024 * 1_024 * 1_024 })
        defer { app.stopProcessing(); source.stop() }
        #expect(await app.startRecording())
        let samples = Data(repeating: 0x37, count: 1_024 * 1_024)
        source.emit(PCMChunk(samples: samples, sampleRate: 16_000))
        await app.finishRecording()
        let entry = try #require(app.history().first)
        let originalVault = try savedFiles(vault)
        let selected = root.appendingPathComponent("selected-folder")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: downloads)
        let output = selected.appendingPathComponent("history.zip")
        let old = Data("Existing selected download".utf8)
        try old.write(to: output)
        let witness = try ExportVaultWitness(vault)
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            started.continuation.yield(())
            started.continuation.finish()
            try await app.exportHistoryZIP(entry.id, to: output)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        // MainActor 只在公开导出等待 detached worker 后续行；原目标仍在证明尚未提交。
        try #require(Data(contentsOf: downloads.appendingPathComponent("history.zip")) == old)
        if redirect {
            try FileManager.default.removeItem(at: selected)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: vault)
            await #expect(throws: DictationError.unsafeExportDestination) { try await task.value }
        } else {
            try await task.value
            let archive = try Data(contentsOf: downloads.appendingPathComponent("history.zip"))
            #expect(archive.starts(with: Data([0x50, 0x4b, 0x03, 0x04])))
            #expect(archive.range(of: samples) != nil)
        }
        let seen = witness.finish()
        #expect(seen.isEmpty, "普通下载或明文 pending 不得出现在加密目录，实际观察：\(seen)")
        #expect(try savedFiles(vault) == originalVault)
        #expect(try app.history().first?.id == entry.id)
        if redirect { #expect(try Data(contentsOf: downloads.appendingPathComponent("history.zip")) == old) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path) == ["history.zip"])
        print("DESTINATION history redirect=\(redirect) vaultPlaintext=\(seen.count) ciphertextUnchanged=\(try savedFiles(vault) == originalVault)")
    }

    @Test(arguments: [false, true])
    func favoritesRejectNewDownloadFilesThroughAnAliasIntoTheVault(json: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-destination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        let favorite = FavoriteFeedback(rawText: "I goes to library.", feedback: CoachFeedback(suggestions: [
            CoachSuggestion(category: .grammar, original: "I goes", improved: "I go", reason: "主语 I 使用 go。")
        ]))
        try store.save(favorite)
        let before = try savedFiles(vault)
        let selected = root.appendingPathComponent("selected-folder")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: vault)
        let output = selected.appendingPathComponent(json ? "new-favorite.json" : "new-favorite.txt")
        #expect(throws: FavoritesError.unsafeExportDestination) {
            if json { try store.exportJSON(favorite.id, to: output) }
            else { try store.exportText(favorite.id, to: output) }
        }
        #expect(try savedFiles(vault) == before)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try store.entry(favorite.id) == favorite)
        print("DESTINATION favorite json=\(json) missingAliasTargetExists=\(FileManager.default.fileExists(atPath: output.path))")
    }

    @Test(arguments: [false, true])
    func favoriteDownloadsRejectFolderChangesDuringSourceKeyLoading(json: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-key-destination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault"), downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let favorite = FavoriteFeedback(rawText: "I goes to library.", feedback: CoachFeedback(suggestions: [
            CoachSuggestion(category: .grammar, original: "I goes", improved: "I go", reason: "主语 I 使用 go。")
        ]))
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        try store.save(favorite)
        let before = try savedFiles(vault)
        let selected = root.appendingPathComponent("selected-folder")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: downloads)
        let outputName = json ? "favorite.json" : "favorite.txt"
        let old = Data("Existing favorite download".utf8)
        try old.write(to: downloads.appendingPathComponent(outputName))
        let keys = ExportRedirectingKey {
            try FileManager.default.removeItem(at: selected)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: vault)
        }
        let reopened = FavoritesStore(vaultRoot: vault, keys: keys)
        let witness = try ExportVaultWitness(vault)
        #expect(throws: FavoritesError.unsafeExportDestination) {
            if json { try reopened.exportJSON(favorite.id, to: selected.appendingPathComponent(outputName)) }
            else { try reopened.exportText(favorite.id, to: selected.appendingPathComponent(outputName)) }
        }
        let seen = witness.finish()
        #expect(seen.isEmpty)
        #expect(keys.loads == 1)
        #expect(try savedFiles(vault) == before)
        #expect(try Data(contentsOf: downloads.appendingPathComponent(outputName)) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path) == [outputName])
        print("DESTINATION favorite keyRedirect json=\(json) vaultPlaintext=\(seen.count) oldDownloadKept=true")
    }

    @Test
    func normalExternalDownloadsReplaceFilesAndReadOnlyDirectoriesPreserveThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("normal-destination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault"), downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let selected = root.appendingPathComponent("selected-folder")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: downloads)
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: vault, keys: TestDataKey())
        defer { app.stopProcessing(); source.stop() }
        #expect(await app.startRecording())
        let samples = Data([0x00, 0x80, 0xff, 0x7f, 0x00, 0x00])
        source.emit(PCMChunk(samples: samples, sampleRate: 16_000))
        await app.finishRecording()
        let id = try #require(app.history().first).id
        let store = FavoritesStore(vaultRoot: vault, keys: TestDataKey())
        let favorite = FavoriteFeedback(rawText: "I goes to library.", feedback: CoachFeedback(suggestions: [
            CoachSuggestion(category: .grammar, original: "I goes", improved: "I go", reason: "主语 I 使用 go。")
        ]))
        try store.save(favorite)
        let before = try savedFiles(vault)
        let audio = selected.appendingPathComponent("audio.wav"), text = selected.appendingPathComponent("favorite.txt")
        let json = selected.appendingPathComponent("favorite.json")
        for output in [audio, text, json] { try Data("Old external file".utf8).write(to: output) }
        try await app.exportHistoryItem(.audio, for: id, to: audio)
        try store.exportText(favorite.id, to: text)
        try store.exportJSON(favorite.id, to: json)
        let wave = try Data(contentsOf: audio)
        #expect(wave.starts(with: Data("RIFF".utf8)))
        #expect(wave.dropFirst(44) == samples)
        let plain = try String(contentsOf: text, encoding: .utf8)
        #expect(plain.contains("I goes to library.") && plain.contains("主语 I 使用 go。"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(FavoriteFeedback.self, from: Data(contentsOf: json)) == favorite)
        let kept = try [audio, text, json].map { try Data(contentsOf: $0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: downloads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloads.path) }
        await #expect(throws: HistoryExportError.cannotWrite) { try await app.exportHistoryItem(.audio, for: id, to: audio) }
        #expect(throws: FavoritesError.storageUnavailable) { try store.exportText(favorite.id, to: text) }
        #expect(throws: FavoritesError.storageUnavailable) { try store.exportJSON(favorite.id, to: json) }
        #expect(try [audio, text, json].map { try Data(contentsOf: $0) } == kept)
        #expect(try savedFiles(vault) == before)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: downloads.path)) == ["audio.wav", "favorite.txt", "favorite.json"])
        print("DESTINATION externalOverwrite=true readonlyErrorsTyped=true previousFilesKept=true pending=0")
    }

    @Test
    func parentCancellationPreservesTheExistingHistoryDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-destination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault"), downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: vault, keys: TestDataKey())
        defer { app.stopProcessing(); source.stop() }
        #expect(await app.startRecording())
        source.emit(PCMChunk(samples: Data(repeating: 0x37, count: 1_024 * 1_024), sampleRate: 16_000))
        await app.finishRecording()
        let id = try #require(app.history().first).id
        let before = try savedFiles(vault)
        let output = downloads.appendingPathComponent("history.zip"), old = Data("Keep original download".utf8)
        try old.write(to: output)
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            started.continuation.yield(())
            started.continuation.finish()
            try await app.exportHistoryZIP(id, to: output)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        try #require(Data(contentsOf: output) == old)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: output) == old)
        #expect(try savedFiles(vault) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path) == ["history.zip"])
        print("DESTINATION parentCancel=true originalDownloadKept=true pending=0")
    }
}

private final class ExportRedirectingKey: LocalDataKeyProviding {
    private let redirect: () throws -> Void
    private(set) var loads = 0
    init(redirect: @escaping () throws -> Void) { self.redirect = redirect }
    func loadKey(createIfMissing: Bool) throws -> Data {
        loads += 1
        try redirect()
        return Data(repeating: 0x9a, count: 32)
    }
}

private final class ExportVaultWitness: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test-own-export-vault")
    private let lock = NSLock()
    private let directory: URL
    private let source: DispatchSourceFileSystemObject
    private let ended = DispatchSemaphore(value: 0)
    private var seen: Set<String> = []

    init(_ directory: URL) throws {
        self.directory = directory
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.capture() }
        let ended = self.ended
        source.setCancelHandler { close(descriptor); ended.signal() }
        source.resume()
    }

    private func capture() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for file in files where file.pathExtension != "enc" {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                _ = lock.withLock { seen.insert(file.lastPathComponent) }
            }
        }
    }

    func finish() -> [String] {
        queue.sync { capture() }
        source.cancel()
        ended.wait()
        return lock.withLock { seen.sorted() }
    }
}
