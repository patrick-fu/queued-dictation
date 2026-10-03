import AVFoundation
import Foundation

public enum AudioCaptureError: Error, Sendable {
    case deviceUnavailable, formatUnsupported, deviceChanged, captureOverrun
}

@MainActor
public final class MicrophoneCapture: AudioCapturing {
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var observer: (any NSObjectProtocol)?
#if NATIVE_ACCEPTANCE
    private let nativeTrace = NativeAcceptanceTrace.shared
    private var nativeCapture: NativeCaptureObservation?
#endif

    public init() {}

    public var authorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    public func requestAuthorization() async -> MicrophoneAuthorization {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return authorization
    }

    public func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        guard authorization == .authorized else { throw DictationError.microphoneUnavailable }
        guard engine == nil else { throw DictationError.alreadyRecording }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate >= 8_000, format.sampleRate <= 192_000,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw AudioCaptureError.formatUnsupported }
        let (stream, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let rate = format.sampleRate
#if NATIVE_ACCEPTANCE
        let observation = nativeTrace?.beginCapture(rate: rate, channels: Int(format.channelCount))
        nativeCapture = observation
        let nativeClock = NativeAcceptanceClock()
#endif
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, time in
            guard let channels = buffer.floatChannelData else {
#if NATIVE_ACCEPTANCE
                NativeAcceptanceTrace.shared?.fail("tap_format_unsupported")
#endif
                continuation.finish(throwing: AudioCaptureError.formatUnsupported)
                return
            }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frames > 0, channelCount > 0 else { return }
#if NATIVE_ACCEPTANCE
            if buffer.format.sampleRate != rate || channelCount != Int(format.channelCount) {
                NativeAcceptanceTrace.shared?.fail("tap_format_changed")
            }
#endif
            var pcm = [Int16](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sample: Float = 0
                for channel in 0..<channelCount { sample += channels[channel][frame] }
                sample /= Float(channelCount)
                guard sample.isFinite else {
#if NATIVE_ACCEPTANCE
                    NativeAcceptanceTrace.shared?.fail("tap_nonfinite_sample")
#endif
                    continuation.finish(throwing: DictationError.invalidAudio); return
                }
                pcm[frame] = Int16(max(-1, min(1, sample)) * 32_767)
            }
            let chunk = PCMChunk(samples: pcm.withUnsafeBytes { Data($0) }, sampleRate: rate)
#if NATIVE_ACCEPTANCE
            let converted = nativeClock.now()
            let yielded = continuation.yield(chunk)
            let yieldedAt = nativeClock.now()
            let result: String
            switch yielded {
            case .enqueued: result = "enqueued"
            case .dropped: result = "dropped"
            case .terminated: result = "terminated"
            @unknown default: result = "unknown"
            }
            observation?.yield(samples: chunk.samples, frames: frames, hostTicks: time.hostTime, hostValid: time.isHostTimeValid,
                sampleTime: time.sampleTime, sampleValid: time.isSampleTimeValid, converted: converted, yieldedAt: yieldedAt, result: result)
            if case .dropped = yielded { continuation.finish(throwing: AudioCaptureError.captureOverrun) }
#else
            if case .dropped = continuation.yield(chunk) {
                continuation.finish(throwing: AudioCaptureError.captureOverrun)
            }
#endif
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
#if NATIVE_ACCEPTANCE
            NativeAcceptanceTrace.shared?.fail("tap_device_changed")
#endif
            continuation.finish(throwing: AudioCaptureError.deviceChanged)
        }
        self.engine = engine
        self.continuation = continuation
        do {
            engine.prepare()
            try engine.start()
        } catch {
#if NATIVE_ACCEPTANCE
            nativeTrace?.fail("capture_start_failed")
#endif
            stop()
            throw AudioCaptureError.deviceUnavailable
        }
        return stream
    }

    public func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        continuation?.finish()
        continuation = nil
#if NATIVE_ACCEPTANCE
        nativeCapture?.finish()
        nativeCapture = nil
#endif
    }
}
