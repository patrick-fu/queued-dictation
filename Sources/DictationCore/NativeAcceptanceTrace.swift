#if NATIVE_ACCEPTANCE
import Carbon
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

enum NativeTraceValue: Sendable {
    case string(String), uint(UInt64), int(Int64), number(Double), flag(Bool)
    var json: Any {
        switch self {
        case .string(let value): value
        case .uint(let value): value
        case .int(let value): value
        case .number(let value): value
        case .flag(let value): value
        }
    }
}

struct NativeAcceptanceClock: Sendable {
    let numer: UInt32
    let denom: UInt32
    init() { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); numer = info.numer; denom = info.denom }
    func nanoseconds(_ ticks: UInt64) -> UInt64? {
        guard denom != 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < UInt64(denom) else { return nil }
        return UInt64(denom).dividingFullWidth(product).quotient
    }
    func now() -> UInt64 { nanoseconds(mach_absolute_time()) ?? 0 }
}

struct NativeHotkeyStamp {
    let value: NativeTraceValue
    let units: String
    let nanoseconds: UInt64?
    let callbackNanoseconds: UInt64
}

final class NativeAcceptanceTrace: @unchecked Sendable {
    static let shared: NativeAcceptanceTrace? = {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "QDNativeAcceptanceRoot") as? String else { return nil }
        guard
              let source = Bundle.main.object(forInfoDictionaryKey: "QDNativeAcceptanceSourceCommit") as? String,
              let data = try? Data(contentsOf: URL(fileURLWithPath: name).appendingPathComponent("native-ready.json")),
              let ready = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let run = ready["run_id"] as? String, UUID(uuidString: run) != nil else {
            fatalError("Native acceptance core trace configuration is invalid.")
        }
        do { return try NativeAcceptanceTrace(root: URL(fileURLWithPath: name), runID: run, source: source) }
        catch { fatalError("Native acceptance core trace output could not be created.") }
    }()

    let clock = NativeAcceptanceClock()
    private let root: URL
    private let runID: String
    private let file: FileHandle
    private let queue = DispatchQueue(label: "queued-dictation.native-trace", qos: .utility)
    private let lock = NSLock()
    private let maximumEvents: Int
    private let maximumBytes: Int
    private var pendingEvents = 0
    private var pendingBytes = 0
    private var sequence: UInt64 = 0
    private var captureIndex = 0
    private var failed = false
    private var failureScheduled = false
    private let osOffset: Int64
    private var outputs: [UUID: (FileHandle, SHA256, UInt64)] = [:]

    init(root: URL, runID: String, source: String, maximumEvents: Int = 512, maximumBytes: Int = 16 * 1_024 * 1_024,
         quartzNow: (() -> UInt64)? = nil) throws {
        self.root = root; self.runID = runID; self.maximumEvents = maximumEvents; self.maximumBytes = maximumBytes
        let a = clock.now(), os = GetCurrentEventTime(), b = clock.now()
        let ua = clock.now(), uptime = ProcessInfo.processInfo.systemUptime, ub = clock.now()
        let osNS = os * 1_000_000_000, uptimeNS = uptime * 1_000_000_000
        let bounded = a > 0 && b >= a && b < UInt64(Int64.max) && ua > 0 && ub >= ua && ub < UInt64(Int64.max) &&
            osNS.isFinite && osNS > 0 && osNS < Double(Int64.max) && uptimeNS.isFinite && uptimeNS > 0 && uptimeNS < Double(Int64.max)
        let carbonOffset = bounded ? Int64(a + (b - a) / 2) - Int64(osNS.rounded()) : 0
        let uptimeOffset = bounded ? Int64(ua + (ub - ua) / 2) - Int64(uptimeNS.rounded()) : 0
        let width = bounded ? max(b - a, ub - ua) : UInt64.max
        let tolerance: UInt64 = 2_000_000
        let qa = clock.now(), fixture = quartzNow?(), qb = clock.now()
        let fixtureValid = fixture.map { value in
            value > 0 && value < UInt64(Int64.max) && qa > 0 && qb >= qa && qb < UInt64(Int64.max) &&
            qb - qa <= 10_000_000 && Int64(qa + (qb - qa) / 2).subtractingReportingOverflow(Int64(value)).partialValue.magnitude <= tolerance
        } ?? true
        let valid = bounded && width <= 10_000_000 && carbonOffset.magnitude <= tolerance && uptimeOffset.magnitude <= tolerance && fixtureValid
        osOffset = carbonOffset
        try FileManager.default.createDirectory(at: root.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("native-core.jsonl")
        guard !FileManager.default.fileExists(atPath: path.path), FileManager.default.createFile(atPath: path.path, contents: nil) else { throw TraceError.output }
        file = try FileHandle(forWritingTo: path)
        var fields: [String: NativeTraceValue] = ["clock_ticks": .uint(mach_absolute_time()), "timebase_numer": .uint(UInt64(clock.numer)),
            "timebase_denom": .uint(UInt64(clock.denom)), "clock_basis": .string("mach_absolute_time"), "source_sha": .string(source)]
        fields["os_calibration_ns"] = .uint(bounded ? UInt64(osNS.rounded()) : 0)
        fields["carbon_value_seconds"] = .number(os.isFinite ? os : -1)
        fields["os_to_mono_offset_ns"] = .int(osOffset)
        fields["calibration_before_ns"] = .uint(a); fields["calibration_after_ns"] = .uint(b)
        fields["quartz_to_mono_offset_ns"] = .int(0)
        fields["quartz_source"] = .string(quartzNow == nil ? "documented_nanoseconds_since_startup" : "synthetic_contract_fixture")
        fields["quartz_epoch_source"] = .string("CoreGraphics/CGEventTypes.h CGEventTimestamp; https://developer.apple.com/documentation/coregraphics/cgeventtimestamp")
        if let fixture {
            fields["quartz_value_ns"] = .uint(fixture); fields["quartz_before_ns"] = .uint(qa); fields["quartz_after_ns"] = .uint(qb)
        }
        fields["process_uptime_seconds"] = .number(uptime.isFinite ? uptime : -1); fields["uptime_before_ns"] = .uint(ua); fields["uptime_after_ns"] = .uint(ub)
        fields["uptime_to_mono_offset_ns"] = .int(uptimeOffset); fields["epoch_tolerance_ns"] = .uint(tolerance)
        fields["calibration_uncertainty_ns"] = .uint(bounded ? width / 2 + max(carbonOffset.magnitude, uptimeOffset.magnitude) + 1 : UInt64.max)
        fields["calibration_valid"] = .flag(valid)
        record("boot", fields: fields)
        if !valid { fail("invalid_calibration") }
    }

    func quartzStamp(_ value: UInt64, callback: UInt64) -> NativeHotkeyStamp {
        NativeHotkeyStamp(value: .uint(value), units: "nanoseconds_since_boot", nanoseconds: value > 0 ? value : nil, callbackNanoseconds: callback)
    }
    func carbonStamp(_ value: Double, callback: UInt64) -> NativeHotkeyStamp {
        let ns = value * 1_000_000_000
        let converted = ns.isFinite && ns > 0 && ns < Double(Int64.max) ? calibrated(UInt64(ns.rounded()), offset: osOffset) : nil
        return NativeHotkeyStamp(value: .number(value.isFinite ? value : -1), units: "seconds_since_boot", nanoseconds: converted, callbackNanoseconds: callback)
    }
    private func calibrated(_ value: UInt64, offset: Int64) -> UInt64? {
        guard value <= UInt64(Int64.max) else { return nil }
        let (ns, overflow) = Int64(value).addingReportingOverflow(offset)
        return !overflow && ns > 0 ? UInt64(ns) : nil
    }
    func hotkey(binding: String, edge: String, accepted: Bool, isRepeat: Bool, stamp: NativeHotkeyStamp) {
        guard let osNS = stamp.nanoseconds, stamp.callbackNanoseconds >= osNS else { fail("invalid_hotkey_clock"); return }
        record("hotkey", at: stamp.callbackNanoseconds, fields: ["binding": .string(binding), "edge": .string(edge),
            "accepted": .flag(accepted), "is_repeat": .flag(isRepeat), "os_value": stamp.value, "os_units": .string(stamp.units),
            "os_ns": .uint(osNS), "callback_ns": .uint(stamp.callbackNanoseconds)])
    }

    func beginCapture(rate: Double, channels: Int) -> NativeCaptureObservation {
        let index = lock.withLock { captureIndex += 1; return captureIndex }
        let capture = NativeCaptureObservation(trace: self, index: index, rate: rate, inputChannels: channels)
        record("capture_start", fields: ["capture_id": .string(capture.id.uuidString), "capture_index": .int(Int64(index)),
            "rate": .number(rate), "channels": .int(Int64(channels))]) { [self] in
                let path = root.appendingPathComponent("captures/\(capture.id).pcm16")
                guard !FileManager.default.fileExists(atPath: path.path), FileManager.default.createFile(atPath: path.path, contents: nil) else { throw TraceError.output }
                outputs[capture.id] = (try FileHandle(forWritingTo: path), SHA256(), 0)
                return nil
            }
        return capture
    }

    func pcm(_ id: UUID, fields: [String: NativeTraceValue], samples: Data, successful: Bool, at: UInt64) {
        record("pcm", at: at, fields: fields, bytes: successful ? samples.count : 0) { [self] in
            guard successful else { return nil }
            guard var output = outputs[id] else { throw TraceError.output }
            try output.0.write(contentsOf: samples)
            output.1.update(data: samples); output.2 += UInt64(samples.count / 2)
            outputs[id] = output
            return nil
        }
    }

    func stopCapture(_ capture: NativeCaptureObservation) {
        let now = clock.now()
        record("capture_stop", at: now, fields: ["capture_id": .string(capture.id.uuidString), "stop_ns": .uint(now)])
        record("capture_finished", fields: ["capture_id": .string(capture.id.uuidString), "capture_index": .int(Int64(capture.index))]) { [self] in
            guard let output = outputs.removeValue(forKey: capture.id) else { throw TraceError.output }
            try output.0.close()
            if output.2 == 0 { fail("no_enqueued_pcm") }
            let digest = output.1.finalize().map { String(format: "%02x", $0) }.joined()
            return ["capture_id": .string(capture.id.uuidString), "capture_index": .int(Int64(capture.index)),
                "enqueued_frames": .uint(output.2), "pcm_sha256": .string(digest), "pcm_path": .string("captures/\(capture.id).pcm16"),
                "trace_failed": .flag(lock.withLock { failed })]
        }
    }

    func record(_ event: String, at: UInt64? = nil, fields: [String: NativeTraceValue], bytes: Int = 0,
                work: (@Sendable () throws -> [String: NativeTraceValue]?)? = nil) {
        let ns = at ?? clock.now()
        lock.lock()
        guard !failed, pendingEvents < maximumEvents, bytes <= maximumBytes - pendingBytes, ns > 0 else {
            lock.unlock(); fail("trace_queue_overflow_or_clock"); return
        }
        pendingEvents += 1; pendingBytes += bytes
        sequence += 1
        let seq = sequence
        queue.async { [self] in
            defer { lock.withLock { pendingEvents -= 1; pendingBytes -= bytes } }
            do {
                var payload = fields
                if let extra = try work?() { payload.merge(extra) { _, new in new } }
                try write(event, sequence: seq, at: ns, fields: payload)
            } catch { fail("trace_io_failure") }
        }
        lock.unlock()
    }
    func fail(_ reason: String) {
        lock.lock()
        failed = true
        guard !failureScheduled else { lock.unlock(); return }
        failureScheduled = true
        queue.async { [self] in
            do { try write("trace_failure", fields: ["reason": .string(reason)]) }
            catch { FileHandle.standardError.write(Data("NATIVE_ACCEPTANCE_FAILURE \(reason)\n".utf8)) }
        }
        lock.unlock()
    }
    private func write(_ event: String, sequence seq: UInt64? = nil, at: UInt64? = nil, fields: [String: NativeTraceValue]) throws {
        let number = seq ?? lock.withLock { sequence += 1; return sequence }
        var object = fields.mapValues(\.json)
        object.merge(["schema_version": 1, "run_id": runID, "event": event, "sequence": number,
            "pid": ProcessInfo.processInfo.processIdentifier, "monotonic_ns": at ?? clock.now()]) { _, new in new }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try file.write(contentsOf: encoded + Data("\n".utf8))
    }
    func drained() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    enum TraceError: Error { case output, clock }
}

final class NativeCaptureObservation: @unchecked Sendable {
    let id = UUID()
    let index: Int
    private let trace: NativeAcceptanceTrace
    private let rate: Double
    private let inputChannels: Int
    private let lock = NSLock()
    private var nextChunk = 0
    private var expectedSample: Int64?
    private var stopped = false
    init(trace: NativeAcceptanceTrace, index: Int, rate: Double, inputChannels: Int) {
        self.trace = trace; self.index = index; self.rate = rate; self.inputChannels = inputChannels
    }
    func yield(samples: Data, frames: Int, hostTicks: UInt64, hostValid: Bool, sampleTime: Int64, sampleValid: Bool,
               converted: UInt64, yieldedAt: UInt64, result: String) {
        lock.lock()
        defer { lock.unlock() }
        let chunk = nextChunk; nextChunk += 1
        if stopped { trace.fail("pcm_after_stop"); return }
        if !hostValid || !sampleValid || frames <= 0 || samples.count != frames * 2 || yieldedAt < converted { trace.fail("invalid_pcm_clock_or_format") }
        if let expectedSample, expectedSample != sampleTime { trace.fail("pcm_sample_discontinuity") }
        expectedSample = sampleTime + Int64(frames)
        let successful = result == "enqueued"
        trace.pcm(id, fields: ["capture_id": .string(id.uuidString), "chunk_index": .int(Int64(chunk)), "frames": .int(Int64(frames)),
            "rate": .number(rate), "channels": .int(1), "input_channels": .int(Int64(inputChannels)), "host_ticks": .uint(hostTicks),
            "host_time_valid": .flag(hostValid), "sample_time": .int(sampleTime), "sample_time_valid": .flag(sampleValid),
            "converted_ns": .uint(converted), "yield_result": .string(result)], samples: samples, successful: successful, at: yieldedAt)
        if !successful { trace.fail("pcm_yield_\(result)") }
    }
    func finish() {
        lock.withLock {
            guard !stopped else { return }; stopped = true
            trace.stopCapture(self)
        }
    }
}
#endif
