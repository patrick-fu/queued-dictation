#if NATIVE_ACCEPTANCE
import CryptoKit
import Foundation
import Testing
@testable import DictationCore

@Suite(.serialized)
struct NativeAcceptanceTraceTests {
    @Test
    func generatedPCMIsWrittenInYieldOrderAndMatchesTheActualEncryptedRecorderExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-trace-contract-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trace = try NativeAcceptanceTrace(root: root, runID: UUID().uuidString, source: "synthetic_contract_fixture", quartzNow: { NativeAcceptanceClock().now() })
        let capture = trace.beginCapture(rate: 8_000, channels: 2)
        let chunks = [Data([0, 0, 0xff, 0x7f]), Data([0, 0x80, 0x42, 0x00])]
        for (index, data) in chunks.enumerated() {
            let converted = trace.clock.now()
            capture.yield(samples: data, frames: 2, hostTicks: UInt64(index + 1), hostValid: true, sampleTime: Int64(index * 2), sampleValid: true,
                converted: converted, yieldedAt: trace.clock.now(), result: "enqueued")
        }
        capture.finish()
        await trace.drained()
        let events = try traceEvents(root)
        #expect(events.first?["quartz_source"] as? String == "synthetic_contract_fixture")
        let pcm = events.filter { $0["event"] as? String == "pcm" }
        #expect(pcm.count == 2 && pcm.map { $0["chunk_index"] as? Int } == [0, 1])
        #expect(pcm.allSatisfy { $0["channels"] as? Int == 1 && $0["input_channels"] as? Int == 2 && $0["yield_result"] as? String == "enqueued" })
        #expect(pcm.allSatisfy { ($0["monotonic_ns"] as? UInt64 ?? 0) >= ($0["converted_ns"] as? UInt64 ?? UInt64.max) })
        let finished = try #require(events.first { $0["event"] as? String == "capture_finished" })
        let samples = chunks.reduce(Data(), +)
        let path = try #require(finished["pcm_path"] as? String)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == samples)
        #expect(finished["enqueued_frames"] as? Int == 4 && finished["trace_failed"] as? Bool == false)
        #expect(finished["pcm_sha256"] as? String == SHA256.hash(data: samples).map { String(format: "%02x", $0) }.joined())
        #expect(events.map { $0["sequence"] as? Int } == Array(1...events.count).map(Optional.some))
        try await verifyGeneratedRecorderExport(root: root, samples: samples)
    }

    @Test
    func aByteLimitOverflowAndASampleGapAreExplicitFailuresRatherThanNativeSamples() async throws {
        for overflow in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-trace-failure-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let trace = try NativeAcceptanceTrace(root: root, runID: UUID().uuidString, source: "synthetic_contract_fixture", maximumBytes: overflow ? 2 : 1_024, quartzNow: { NativeAcceptanceClock().now() })
            let capture = trace.beginCapture(rate: 8_000, channels: 1)
            await trace.drained()
            let data = Data([0, 0, 1, 0])
            let at = trace.clock.now()
            capture.yield(samples: data, frames: 2, hostTicks: 1, hostValid: true, sampleTime: 0, sampleValid: true, converted: at, yieldedAt: at, result: "enqueued")
            if !overflow { capture.yield(samples: data, frames: 2, hostTicks: 2, hostValid: true, sampleTime: 9, sampleValid: true, converted: at, yieldedAt: at, result: "enqueued") }
            capture.finish()
            await trace.drained(); await trace.drained()
            let failures = try traceEvents(root).filter { $0["event"] as? String == "trace_failure" }
            #expect(failures.count == 1)
            #expect(failures.first?["reason"] as? String == (overflow ? "trace_queue_overflow_or_clock" : "pcm_sample_discontinuity"))
        }
    }

    @Test
    func invalidNativeEventTimeFailsInsteadOfBeingReplacedWithItsCallbackTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-clock-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trace = try NativeAcceptanceTrace(root: root, runID: UUID().uuidString, source: "synthetic_contract_fixture", quartzNow: { NativeAcceptanceClock().now() })
        trace.hotkey(binding: "fn", edge: "down", accepted: true, isRepeat: false,
            stamp: NativeHotkeyStamp(value: .uint(0), units: "nanoseconds_since_boot", nanoseconds: nil, callbackNanoseconds: trace.clock.now()))
        await trace.drained(); await trace.drained()
        let events = try traceEvents(root)
        #expect(events.contains { $0["event"] as? String == "trace_failure" && $0["reason"] as? String == "invalid_hotkey_clock" })
        #expect(!events.contains { $0["event"] as? String == "hotkey" })
    }

    @Test
    func fnPayloadPreservesItsQueuedDelayWithoutAnEmpiricalQuartzOffset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-clock-payload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trace = try NativeAcceptanceTrace(root: root, runID: UUID().uuidString, source: "synthetic_contract_fixture", quartzNow: { NativeAcceptanceClock().now() - 1_000_000 })
        let callback = trace.clock.now(), value = callback - 20_000_000
        trace.hotkey(binding: "fn", edge: "down", accepted: true, isRepeat: false, stamp: trace.quartzStamp(value, callback: callback))
        await trace.drained()
        let events = try traceEvents(root)
        let hotkey = try #require(events.first { $0["event"] as? String == "hotkey" })
        #expect(hotkey["os_ns"] as? UInt64 == value)
        #expect((hotkey["callback_ns"] as? UInt64 ?? 0) - (hotkey["os_ns"] as? UInt64 ?? 0) == 20_000_000)
        #expect(events.first?["quartz_to_mono_offset_ns"] as? Int == 0)
    }

    @Test
    func anUnavailableIndependentCalibrationIsRecordedAsInvalid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-calibration-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trace = try NativeAcceptanceTrace(root: root, runID: UUID().uuidString, source: "synthetic_contract_fixture", quartzNow: { 0 })
        await trace.drained()
        let events = try traceEvents(root)
        #expect(events.first?["calibration_valid"] as? Bool == false)
        #expect(events.first?["quartz_value_ns"] as? Int == 0)
        #expect(events.contains { $0["event"] as? String == "trace_failure" && $0["reason"] as? String == "invalid_calibration" })
    }

    @Test
    func aBlockedWriterCannotGrowTheEventQueueAndAnOutputFailureCannotPass() async throws {
        for overflow in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-writer-failure-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let trace = try NativeAcceptanceTrace(root: root, runID: UUID().uuidString, source: "synthetic_contract_fixture", maximumEvents: overflow ? 1 : 512, quartzNow: { NativeAcceptanceClock().now() })
            await trace.drained()
            let gate = DispatchSemaphore(value: 0)
            if overflow { trace.record("held_writer", fields: [:]) { gate.wait(); return nil } }
            else {
                try FileManager.default.removeItem(at: root.appendingPathComponent("captures"))
                try Data().write(to: root.appendingPathComponent("captures"))
            }
            let capture = trace.beginCapture(rate: 8_000, channels: 1)
            gate.signal()
            capture.finish()
            await trace.drained(); await trace.drained()
            let failures = try traceEvents(root).filter { $0["event"] as? String == "trace_failure" }
            #expect(failures.count == 1)
            #expect(failures.first?["reason"] as? String == (overflow ? "trace_queue_overflow_or_clock" : "trace_io_failure"))
        }
    }
}

private func traceEvents(_ root: URL) throws -> [[String: Any]] {
    try String(contentsOf: root.appendingPathComponent("native-core.jsonl"), encoding: .utf8).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
}
@MainActor
private func verifyGeneratedRecorderExport(root: URL, samples: Data) async throws {
    let source = TraceGeneratedSource()
    let recorder = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TraceGeneratedKey())
    #expect(await recorder.startRecording())
    source.send(PCMChunk(samples: samples, sampleRate: 8_000))
    await recorder.finishRecording()
    let entry = try #require(recorder.history().first)
    #expect(entry.frameCount == 4)
    let output = root.appendingPathComponent("export.wav")
    try recorder.exportAudio(entry.id, to: output)
    #expect(try Data(contentsOf: output).dropFirst(44) == samples)
    recorder.stopProcessing()
}
@MainActor
private final class TraceGeneratedSource: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { continuation = $0 } }
    func send(_ chunk: PCMChunk) { continuation?.yield(chunk) }
    func stop() { continuation?.finish() }
}
private struct TraceGeneratedKey: LocalDataKeyProviding {
    func loadKey(createIfMissing: Bool) throws -> Data { Data(repeating: 0x9A, count: 32) }
}
#endif
