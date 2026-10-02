import AVFAudio
import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct RecordingBehaviorTests {
    @Test
    func audioDownloadCannotOverwriteFilesInsideTheEncryptedDataDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let entry = try #require(app.history().first)
        let original = try savedFiles(directory)
        #expect(throws: DictationError.unsafeExportDestination) {
            try app.exportAudio(entry.id, to: directory.appendingPathComponent("vault.enc"))
        }
        #expect(try savedFiles(directory) == original)
    }

    @Test
    func idleMicrophoneChangesRefreshDisplayedPermissionOnlyWhenItChanges() throws {
        let source = ControlledMicrophone()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        var displayedPermissions: [MicrophoneAuthorization] = []
        app.onChange = { displayedPermissions.append(app.microphoneAuthorization) }
        source.authorization = .denied
        app.checkRecordingConditions()
        #expect(displayedPermissions == [.denied])
        app.checkRecordingConditions()
        #expect(displayedPermissions == [.denied])
        source.authorization = .authorized
        app.checkRecordingConditions()
        #expect(displayedPermissions == [.denied, .authorized])
        #expect(app.state == .ready)
    }

    @Test
    func unreadableDataDirectoryRefusesRecordingWithoutCreatingAKeyOrChangingTheVault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let original = try savedFiles(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory.path)
        let keys = MissingDataKey()
        let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory, keys: keys)
        #expect(await restarted.startRecording() == false)
        await restarted.cancelCurrentRecording()
        #expect(keys.creationRequests == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try savedFiles(directory) == original)
    }

    @Test
    func cancellingPermissionRequestDoesNotStartCaptureAfterPermissionArrives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        source.authorization = .notDetermined
        source.holdAuthorization = true
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        let request = Task { await app.startRecording() }
        try await waitUntil { app.state == .requestingMicrophone }
        await app.cancelCurrentRecording()
        source.completeAuthorization(.authorized)
        #expect(await request.value == false)
        #expect(app.state == .ready)
        #expect(try app.history().isEmpty)
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        #expect(try app.history().count == 1)
    }

    @Test
    func captureFailureKeepsValidAudioAndCorruptedCiphertextCannotBeDownloaded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        source.fail(AudioCaptureError.deviceChanged)
        await app.finishRecording()
        let entry = try #require(app.history().first)
        #expect(entry.duration == 0.5)
        let path = directory.appendingPathComponent("history/\(entry.id)/00000000.audio")
        var ciphertext = try Data(contentsOf: path)
        ciphertext[ciphertext.count - 1] ^= 1
        try ciphertext.write(to: path)
        let download = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: download) }
        #expect(throws: DictationError.unreadableHistory) { try app.exportAudio(entry.id, to: download) }
        #expect(!FileManager.default.fileExists(atPath: download.path))
    }

    @Test
    func localQuotaDuringRecordingStopsAndKeepsOnlyTheValidSavedPart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey(),
                                       limits: RecordingLimits(maximumLocalBytes: 1_090_000))
        #expect(await app.startRecording())
        for _ in 0..<10 { source.emit(testAudio()) }
        await app.finishRecording()
        let entry = try #require(app.history().first)
        #expect(entry.duration > 0 && entry.duration < 5)
        #expect(app.notice?.contains("本地数据") == true)
        #expect(try savedFiles(directory).values.reduce(0) { $0 + $1.count } <= 1_090_000)
        let download = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: download) }
        try app.exportAudio(entry.id, to: download)
        #expect(try AVAudioFile(forReading: download).length > 0)
    }

    @Test
    func defaultFiveGiBQuotaRefusesNewRecordingAndKeepsExistingAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let original = try app.history()
        let padding = directory.appendingPathComponent("quota-fixture")
        #expect(FileManager.default.createFile(atPath: padding.path, contents: nil))
        let file = try FileHandle(forWritingTo: padding)
        try file.truncate(atOffset: 5 * 1_024 * 1_024 * 1_024)
        try file.close()
        let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory, keys: TestDataKey())
        #expect(await restarted.startRecording() == false)
        #expect(restarted.notice?.contains("本地数据") == true)
        #expect(try restarted.history() == original)
    }

    @Test
    func diskSpaceLossDuringRecordingPreservesTheAlreadySavedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let disk = ControlledDiskSpace()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey(), diskSpace: { _ in disk.bytes })
        #expect(await app.startRecording())
        source.emit(testAudio())
        try await waitUntil {
            if case .recording(_, let duration) = app.state { return duration == 0.5 }
            return false
        }
        disk.bytes = 1_024
        source.emit(testAudio())
        await app.finishRecording()
        #expect(try app.history().first?.duration == 0.5)
        #expect(app.notice?.contains("磁盘") == true)
    }

    @Test
    func noAudioCreatesNoHistoryAndRevokedMicrophoneStillAllowsSavedAudioDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        #expect(await app.startRecording() == false)
        await app.finishRecording()
        #expect(try app.history().isEmpty)
        #expect(app.notice?.contains("没有采集到") == true)
        #expect(await app.startRecording())
        source.emit(testAudio())
        try await waitUntil {
            if case .recording(_, let duration) = app.state { return duration == 0.5 }
            return false
        }
        source.authorization = .denied
        app.checkRecordingConditions()
        await app.finishRecording()
        let entry = try #require(app.history().first)
        #expect(entry.duration == 0.5)
        #expect(app.notice?.contains("撤销") == true)
        #expect(await app.startRecording() == false)
        let download = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: download) }
        try app.exportAudio(entry.id, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
    }

    @Test
    func defaultRetentionRemovesThirtyDayTerminalHistoryButKeepsUnfinishedSegments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey(), now: { oldDate })
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let unfinished = try #require(app.history().first)
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let terminal = try #require(app.history().first { $0.id != unfinished.id })
        try app.cancelRecordedSegment(terminal.id)
        let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory,
                                            keys: TestDataKey(), now: { oldDate.addingTimeInterval(31 * 86_400) })
        #expect(try restarted.history().map(\.id) == [unfinished.id])
        let download = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: download) }
        try restarted.exportAudio(unfinished.id, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
    }

    @Test
    func recordingDataIsEncryptedFromTheFirstSavedChunkAndMissingKeysNeverOverwriteIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        try await waitUntil {
            if case .recording(_, let duration) = app.state { return duration == 0.5 }
            return false
        }
        let duringRecording = try savedFiles(directory)
        #expect(duringRecording.count >= 2)
        for bytes in duringRecording.values {
            #expect(bytes.starts(with: Data("QDENC1".utf8)))
            #expect(bytes.range(of: testAudio().samples.prefix(64)) == nil)
            #expect(bytes.range(of: Data("awaitingProcessing".utf8)) == nil)
            #expect(bytes.range(of: TestDataKey().bytes) == nil)
        }
        await app.finishRecording()
        let originalFiles = try savedFiles(directory)
        let lostKeys = MissingDataKey()
        let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory, keys: lostKeys)
        #expect(throws: DictationError.dataKeyUnavailable) { try restarted.history() }
        #expect(await restarted.startRecording() == false)
        #expect(lostKeys.creationRequests == 0)
        #expect(try savedFiles(directory) == originalFiles)
        let wrongKey = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory,
                                           keys: WrongDataKey())
        #expect(throws: DictationError.unreadableHistory) { try wrongKey.history() }
        #expect(try savedFiles(directory) == originalFiles)
    }

    @Test
    func cancellingCurrentRecordingLeavesEarlierAudioAndRecordedCancellationKeepsDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let original = try #require(app.history().first)
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.cancelCurrentRecording()
        #expect(try app.history() == [original])
        try app.cancelRecordedSegment(original.id)
        let cancelled = try #require(app.history().first)
        #expect(cancelled.disposition == .cancelled)
        let download = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: download) }
        try app.exportAudio(original.id, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
    }

    @Test
    func lowRealDiskSpaceRefusesRecordingWithoutDiscardingExistingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let saved = try app.history()
        let noSpace = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory,
                                          keys: TestDataKey(), diskSpace: { _ in 1_024 })
        #expect(await noSpace.startRecording() == false)
        #expect(try noSpace.history() == saved)
        #expect(noSpace.notice?.contains("磁盘") == true)
        await noSpace.cancelCurrentRecording()
    }

    @Test
    func defaultDurationLimitStopsAtFiveMinutesAndKeepsValidAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: TestDataKey())
        #expect(await app.startRecording())
        for _ in 0..<602 { source.emit(testAudio()) }
        await app.finishRecording()
        let entry = try #require(app.history().first)
        #expect(entry.duration == 300)
        #expect(app.notice?.contains("时长上限") == true)
    }

    @Test
    func finishedRecordingCanBeReadAfterRestartAndDownloadedAsPlayableAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ControlledMicrophone()
        let keys = TestDataKey()
        let app = RecordingApplication(source: source, historyDirectory: directory, keys: keys)
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()

        let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: directory, keys: keys)
        let entry = try #require(restarted.history().first)
        #expect(entry.duration == 0.5)
        let download = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: download) }
        try restarted.exportAudio(entry.id, to: download)
        let audio = try AVAudioFile(forReading: download)
        #expect(audio.length == 4_000)
        #expect(audio.fileFormat.sampleRate == 8_000)
        let bytes = try Data(contentsOf: download)
        #expect(String(data: bytes.prefix(4), encoding: .ascii) == "RIFF")
        #expect(bytes.suffix(testAudio().samples.count) == testAudio().samples)
    }
}

@MainActor
final class ControlledMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    var holdAuthorization = false
    private var permissionRequest: CheckedContinuation<MicrophoneAuthorization, Never>?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization {
        if holdAuthorization { return await withCheckedContinuation { permissionRequest = $0 } }
        return authorization
    }
    func completeAuthorization(_ result: MicrophoneAuthorization) {
        authorization = result
        holdAuthorization = false
        permissionRequest?.resume(returning: result)
        permissionRequest = nil
    }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        AsyncThrowingStream { continuation = $0 }
    }
    func emit(_ audio: PCMChunk) { continuation?.yield(audio) }
    func fail(_ error: any Error) { continuation?.finish(throwing: error) }
    func stop() { continuation?.finish() }
}

struct TestDataKey: LocalDataKeyProviding {
    let bytes = Data(repeating: 0x9A, count: 32)
    func loadKey(createIfMissing: Bool) throws -> Data { bytes }
}

final class MissingDataKey: LocalDataKeyProviding {
    var creationRequests = 0
    func loadKey(createIfMissing: Bool) throws -> Data {
        if createIfMissing { creationRequests += 1; return Data(repeating: 0, count: 32) }
        throw DictationError.dataKeyUnavailable
    }
}

final class ControlledDiskSpace { var bytes: UInt64 = 100 * 1_024 * 1_024 }

struct WrongDataKey: LocalDataKeyProviding {
    func loadKey(createIfMissing: Bool) throws -> Data { Data(repeating: 0x2B, count: 32) }
}

func savedFiles(_ directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    if let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let url as URL in iterator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
    }
    return result
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestWaitError.timedOut }
        await Task.yield()
    }
}

enum TestWaitError: Error { case timedOut }

func testAudio() -> PCMChunk {
    let samples: [Int16] = Array(repeating: [0, 8_000, -8_000, 0], count: 1_000).flatMap { $0 }
    return PCMChunk(samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 8_000)
}
