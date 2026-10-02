import CryptoKit
import Foundation

@MainActor
final class HistoryDraft {
    let id = UUID()
    let recordedAt: Date
    let recordingOrder: UInt64
    var sampleRate: Double = 0
    var frameCount = 0
    var chunkCount = 0
    var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    init(recordedAt: Date, recordingOrder: UInt64) { self.recordedAt = recordedAt; self.recordingOrder = recordingOrder }
}

private struct StoredDraft: Codable {
    let id: UUID
    let recordedAt: Date
    let recordingOrder: UInt64
    let sampleRate: Double
    let frameCount: Int
    let chunkCount: Int
    let stage: QueueStage
}

private struct StoredEntry: Codable {
    var entry: VoiceHistoryEntry
    let chunkCount: Int
}

@MainActor
final class EncryptedHistory {
    let directory: URL
    private let keys: any LocalDataKeyProviding
    private var key: SymmetricKey?
    private let files = FileManager.default
    private let magic = Data("QDENC1".utf8)
    private var knownUsage: UInt64?
    private var knownAudioBytes: [UUID: UInt64] = [:]

    init(directory: URL, keys: any LocalDataKeyProviding) {
        self.directory = directory
        self.keys = keys
    }

    func begin(at date: Date) throws -> HistoryDraft {
        try open()
        let draft = HistoryDraft(recordedAt: date, recordingOrder: try reserveRecordingOrder())
        try files.createDirectory(at: activeDirectory(draft.id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { try checkpoint(draft) }
        catch { try? files.removeItem(at: activeDirectory(draft.id)); throw error }
        knownAudioBytes[draft.id] = 0
        return draft
    }

    func append(_ chunk: PCMChunk, to draft: HistoryDraft) throws {
        guard chunk.sampleRate.isFinite, chunk.sampleRate >= 8_000, chunk.sampleRate <= 192_000,
              !chunk.samples.isEmpty, chunk.samples.count.isMultiple(of: 2), chunk.samples.count <= 1_048_576,
              draft.sampleRate == 0 || draft.sampleRate == chunk.sampleRate else { throw DictationError.invalidAudio }
        let path = activeDirectory(draft.id).appendingPathComponent(chunkName(draft.chunkCount))
        let prior = try audioBytes(draft.id, active: true)
        knownAudioBytes[draft.id] = nil
        let allocation = try write(chunk.samples, to: path, context: "\(draft.id)/audio/\(draft.chunkCount)")
        guard prior >= allocation.previous else { throw DictationError.storageUnavailable }
        let (total, overflow) = (prior - allocation.previous).addingReportingOverflow(allocation.current)
        guard !overflow else { throw DictationError.storageUnavailable }
        knownAudioBytes[draft.id] = total
        draft.sampleRate = chunk.sampleRate
        draft.frameCount += chunk.samples.count / 2
        draft.chunkCount += 1
        try checkpoint(draft)
    }

    private func checkpoint(_ draft: HistoryDraft) throws {
        let saved = StoredDraft(id: draft.id, recordedAt: draft.recordedAt, recordingOrder: draft.recordingOrder,
            sampleRate: draft.sampleRate, frameCount: draft.frameCount, chunkCount: draft.chunkCount, stage: .recording)
        try write(JSONEncoder().encode(saved), to: activeDirectory(draft.id).appendingPathComponent("draft.enc"), context: "\(draft.id)/draft")
    }

    func commit(_ draft: HistoryDraft, endedAt: Date) throws {
        let entry = VoiceHistoryEntry(id: draft.id, recordedAt: draft.recordedAt, sampleRate: draft.sampleRate,
                                     frameCount: draft.frameCount, disposition: .awaitingProcessing, recordingOrder: draft.recordingOrder,
                                     queueStage: .waitingForSlot, recordingEndedAt: endedAt)
        do {
            let metadata = try JSONEncoder().encode(StoredEntry(entry: entry, chunkCount: draft.chunkCount))
            try write(metadata, to: activeDirectory(draft.id).appendingPathComponent("entry.enc"), context: "\(draft.id)/entry")
            let history = directory.appendingPathComponent("history", isDirectory: true)
            try files.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.moveItem(at: activeDirectory(draft.id), to: historyDirectory(draft.id))
        } catch {
            knownAudioBytes[draft.id] = nil
            knownUsage = nil
            throw error
        }
    }

    func discard(_ draft: HistoryDraft) throws {
        knownAudioBytes[draft.id] = nil
        knownUsage = nil
        try files.removeItem(at: activeDirectory(draft.id))
    }

    func invalidateUsage() { knownUsage = nil }

    func entryStorageBytes(_ id: UUID) throws -> UInt64 {
        try open()
        return UInt64(try JSONEncoder().encode(readEntry(id)).count + 34)
    }

    func bytesOnDisk() throws -> UInt64 {
        if let knownUsage { return knownUsage }
        guard !(try directoryContents()).isEmpty else { knownUsage = 0; return 0 }
        var total: UInt64 = 0
        var enumerationFailed = false
        guard let iterator = files.enumerator(at: directory,
                                              includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey],
                                              errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw DictationError.storageUnavailable
        }
        for case let url as URL in iterator {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw DictationError.storageUnavailable }
            if info.isRegularFile == true { total += try footprint(of: url) }
        }
        guard !enumerationFailed else { throw DictationError.storageUnavailable }
        knownUsage = total
        return total
    }

    func entries() throws -> [VoiceHistoryEntry] {
        guard !(try directoryContents()).isEmpty else { return [] }
        try open()
        let history = directory.appendingPathComponent("history", isDirectory: true)
        guard files.fileExists(atPath: history.path) else { return [] }
        return try files.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { path in
                guard let id = UUID(uuidString: path.lastPathComponent) else { throw DictationError.unreadableHistory }
                return try readEntry(id).entry
            }.sorted { $0.recordedAt != $1.recordedAt ? $0.recordedAt > $1.recordedAt : ($0.recordingOrder ?? 0) > ($1.recordingOrder ?? 0) }
    }

    private func reserveRecordingOrder() throws -> UInt64 {
        let path = directory.appendingPathComponent("recording-order.enc")
        let last: UInt64
        if files.fileExists(atPath: path.path) {
            do { last = try JSONDecoder().decode(UInt64.self, from: read(path, context: "recording-order-v1")) }
            catch { throw DictationError.unreadableHistory }
        } else { last = try entries().compactMap(\.recordingOrder).max() ?? 0 }
        guard last < UInt64.max else { throw DictationError.storageUnavailable }
        try write(JSONEncoder().encode(last + 1), to: path, context: "recording-order-v1")
        return last + 1
    }

    func audioBytes(_ id: UUID, active: Bool = false) throws -> UInt64 {
        if let saved = knownAudioBytes[id] { return saved }
        let path = active ? activeDirectory(id) : historyDirectory(id)
        var total: UInt64 = 0
        for file in try files.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) where file.pathExtension == "audio" {
            let (next, overflow) = total.addingReportingOverflow(try footprint(of: file))
            guard !overflow else { throw DictationError.storageUnavailable }
            total = next
        }
        knownAudioBytes[id] = total
        return total
    }

    func setDisposition(_ disposition: MainDisposition, for id: UUID) throws {
        try updateEntry(id) { $0.disposition = disposition }
    }

    func entry(_ id: UUID) throws -> VoiceHistoryEntry {
        try open()
        return try readEntry(id).entry
    }

    func updateEntry(_ id: UUID, capacity: ((UInt64) throws -> Void)? = nil, _ update: (inout VoiceHistoryEntry) -> Void) throws {
        try open()
        var stored = try readEntry(id)
        update(&stored.entry)
        let metadata = try JSONEncoder().encode(stored)
        try capacity?(UInt64((metadata.count + 34 + 4_095) / 4_096 * 4_096))
        try write(metadata, to: historyDirectory(id).appendingPathComponent("entry.enc"), context: "\(id)/entry")
    }

    func delete(_ id: UUID) throws {
        try open()
        _ = try readEntry(id)
        knownAudioBytes[id] = nil
        knownUsage = nil
        try files.removeItem(at: historyDirectory(id))
    }

    func waveAudio(_ id: UUID) throws -> Data {
        try open()
        let stored = try readEntry(id)
        var pcm = Data()
        for index in 0..<stored.chunkCount {
            pcm.append(try read(historyDirectory(id).appendingPathComponent(chunkName(index)), context: "\(id)/audio/\(index)"))
        }
        guard pcm.count == stored.entry.frameCount * 2 else { throw DictationError.unreadableHistory }
        var wave = Data("RIFF".utf8)
        wave.appendLittleEndian(UInt32(pcm.count + 36))
        wave.append(Data("WAVEfmt ".utf8))
        wave.appendLittleEndian(UInt32(16))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(UInt16(1))
        let rate = UInt32(stored.entry.sampleRate)
        wave.appendLittleEndian(rate)
        wave.appendLittleEndian(rate * 2)
        wave.appendLittleEndian(UInt16(2))
        wave.appendLittleEndian(UInt16(16))
        wave.append(Data("data".utf8))
        wave.appendLittleEndian(UInt32(pcm.count))
        wave.append(pcm)
        return wave
    }

    private func open() throws {
        if key != nil { return }
        let existing = !(try directoryContents()).isEmpty
        let bytes: Data
        do { bytes = try keys.loadKey(createIfMissing: !existing) }
        catch { throw DictationError.dataKeyUnavailable }
        guard bytes.count == 32 else { throw DictationError.dataKeyUnavailable }
        key = SymmetricKey(data: bytes)
        do {
            let marker = directory.appendingPathComponent("vault.enc")
            if existing {
                guard try read(marker, context: "vault-v1") == Data("queued-dictation-vault-1".utf8) else {
                    throw DictationError.unreadableHistory
                }
            } else {
                try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try write(Data("queued-dictation-vault-1".utf8), to: marker, context: "vault-v1")
            }
        } catch {
            key = nil
            throw DictationError.unreadableHistory
        }
    }

    private func readEntry(_ id: UUID) throws -> StoredEntry {
        let url = historyDirectory(id).appendingPathComponent("entry.enc")
        guard files.fileExists(atPath: url.path) else { throw DictationError.missingHistory }
        do {
            let stored = try JSONDecoder().decode(StoredEntry.self, from: read(url, context: "\(id)/entry"))
            guard stored.entry.id == id, stored.entry.frameCount > 0, stored.chunkCount > 0 else { throw DictationError.unreadableHistory }
            return stored
        } catch { throw DictationError.unreadableHistory }
    }

    @discardableResult
    private func write(_ data: Data, to url: URL, context: String) throws -> (previous: UInt64, current: UInt64) {
        guard let key else { throw DictationError.dataKeyUnavailable }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let combined = sealed.combined else { throw DictationError.storageUnavailable }
        let ciphertext = magic + combined
        let used = knownUsage
        knownUsage = nil
        let previous: UInt64
        do { previous = try footprint(of: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { previous = 0 }
        try ciphertext.write(to: url, options: .atomic)
        let current = try footprint(of: url)
        if let used, used >= previous {
            let (total, overflow) = (used - previous).addingReportingOverflow(current)
            guard !overflow else { throw DictationError.storageUnavailable }
            knownUsage = total
        }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (previous, current)
    }

    private func read(_ url: URL, context: String) throws -> Data {
        guard let key else { throw DictationError.dataKeyUnavailable }
        do {
            let data = try Data(contentsOf: url)
            guard data.starts(with: magic) else { throw DictationError.unreadableHistory }
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch { throw DictationError.unreadableHistory }
    }

    private func activeDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("active/\(id)", isDirectory: true) }
    private func historyDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("history/\(id)", isDirectory: true) }
    private func chunkName(_ index: Int) -> String { String(format: "%08d.audio", index) }

    private func footprint(of url: URL) throws -> UInt64 {
        var measured = url
        measured.removeAllCachedResourceValues()
        let info = try measured.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, let allocated = info.totalFileAllocatedSize,
              size >= 0, allocated >= 0 else { throw DictationError.storageUnavailable }
        return UInt64(max(size, allocated))
    }

    private func directoryContents() throws -> [URL] {
        do {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw DictationError.storageUnavailable }
            return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return [] }
            throw DictationError.storageUnavailable
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
