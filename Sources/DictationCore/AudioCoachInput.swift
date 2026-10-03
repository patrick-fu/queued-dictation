import Foundation

public struct AudioCoachInput: Sendable {
    public let wave: Data
    public let duration: TimeInterval
    public let sampleRate: UInt32
    public var format: String { "wav" }
    // 历史录音为单声道 PCM16；上限覆盖 192 kHz、60 分钟及有界 WAV 元数据。
    public static let maximumWAVBytes = 192_000 * 2 * 3_600 + 65_536
    public static let maximumRequestBytes = ((maximumWAVBytes + 2) / 3) * 4 + 4 * 1_024 * 1_024

    public init(wave: Data) throws {
        guard wave.count <= Self.maximumWAVBytes else { throw CoachFailure.audioTooLarge }
        let facts = try wave.withUnsafeBytes { bytes -> (UInt32, Int) in
            guard bytes.count >= 44, Self.tag(bytes, at: 0) == "RIFF", Self.tag(bytes, at: 8) == "WAVE",
                  Int(Self.uint32(bytes, at: 4)) == bytes.count - 8 else { throw CoachFailure.invalidAudio }
            var offset = 12, rate: UInt32?, audioBytes: Int?
            while offset < bytes.count {
                guard bytes.count - offset >= 8 else { throw CoachFailure.invalidAudio }
                let tag = Self.tag(bytes, at: offset), size = Int(Self.uint32(bytes, at: offset + 4))
                let start = offset + 8
                guard size <= bytes.count - start, size + (size % 2) <= bytes.count - start else {
                    throw CoachFailure.invalidAudio
                }
                if tag == "fmt " {
                    guard rate == nil, size == 16 || (size == 18 && Self.uint16(bytes, at: start + 16) == 0),
                          Self.uint16(bytes, at: start) == 1, Self.uint16(bytes, at: start + 2) == 1,
                          Self.uint16(bytes, at: start + 12) == 2, Self.uint16(bytes, at: start + 14) == 16 else {
                        throw CoachFailure.invalidAudio
                    }
                    let sampleRate = Self.uint32(bytes, at: start + 4)
                    guard (8_000...192_000).contains(sampleRate), Self.uint32(bytes, at: start + 8) == sampleRate * 2 else {
                        throw CoachFailure.invalidAudio
                    }
                    rate = sampleRate
                } else if tag == "data" {
                    guard rate != nil, audioBytes == nil, size > 0, size % 2 == 0 else { throw CoachFailure.invalidAudio }
                    audioBytes = size
                }
                offset = start + size + size % 2
            }
            guard let rate, let audioBytes, bytes.count - audioBytes <= 65_536 else { throw CoachFailure.invalidAudio }
            return (rate, audioBytes)
        }
        let duration = Double(facts.1 / 2) / Double(facts.0)
        guard duration > 0, duration <= 3_600 else { throw CoachFailure.audioTooLarge }
        self.wave = wave; self.duration = duration; self.sampleRate = facts.0
    }

    private static func tag(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }
    private static func uint16(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    private static func uint32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
