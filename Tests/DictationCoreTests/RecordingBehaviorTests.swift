import AVFAudio
import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct RecordingBehaviorTests {
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
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        AsyncThrowingStream { continuation = $0 }
    }
    func emit(_ audio: PCMChunk) { continuation?.yield(audio) }
    func stop() { continuation?.finish() }
}

struct TestDataKey: LocalDataKeyProviding {
    let bytes = Data(repeating: 0x9A, count: 32)
    func loadKey(createIfMissing: Bool) throws -> Data { bytes }
}

func testAudio() -> PCMChunk {
    let samples: [Int16] = Array(repeating: [0, 8_000, -8_000, 0], count: 1_000).flatMap { $0 }
    return PCMChunk(samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 8_000)
}
