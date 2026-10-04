import AVFoundation
import Foundation
import Testing
@testable import DictationCore

@MainActor
struct MicrophoneCallbackBehaviorTests {
    @Test
    func theAudioCallbackDeliversPCMFromAnAudioThread() async throws {
        let (stream, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let capture = MicrophoneCapture()
        let delivery = AudioCallbackDelivery(block: capture.makeTapBlock(rate: 48_000,
            inputChannelCount: 2, continuation: continuation), continuation: continuation)
        let wasAudioThread = await withCheckedContinuation { done in
            DispatchQueue(label: "microphone-callback-test").async {
                delivery.invoke()
                done.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(wasAudioThread)
        var iterator = stream.makeAsyncIterator()
        let chunk = try #require(try await iterator.next())
        let expected: [Int16] = [0, 8_191, -24_575, 24_575]
        #expect(chunk.samples == expected.withUnsafeBytes { Data($0) })
        #expect(chunk.sampleRate == 48_000)
        #expect(try await iterator.next() == nil)
    }
}

// AVFAudio transfers its legacy, non-Sendable block to an audio thread.
private final class AudioCallbackDelivery: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    let continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation

    init(block: @escaping AVAudioNodeTapBlock,
         continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation) {
        self.block = block
        self.continuation = continuation
    }

    func invoke() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4),
              let channels = buffer.floatChannelData else {
            continuation.finish(throwing: AudioCaptureError.formatUnsupported)
            return
        }
        buffer.frameLength = 4
        let left: [Float] = [1, 0, -1, 0.5]
        let right: [Float] = [-1, 0.5, -0.5, 1]
        for i in 0..<4 {
            channels[0][i] = left[i]
            channels[1][i] = right[i]
        }
        block(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        continuation.finish()
    }
}
