import Foundation

public enum MicrophoneAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

public struct PCMChunk: Sendable {
    public let samples: Data
    public let sampleRate: Double

    public init(samples: Data, sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public struct RecordingLimits: Sendable {
    public let maximumDuration: TimeInterval
    public let maximumLocalBytes: UInt64

    public init(maximumDuration: TimeInterval = 300, maximumLocalBytes: UInt64 = 5 * 1_024 * 1_024 * 1_024) {
        self.maximumDuration = maximumDuration
        self.maximumLocalBytes = maximumLocalBytes
    }
}

@MainActor
public protocol AudioCapturing: AnyObject {
    var authorization: MicrophoneAuthorization { get }
    func requestAuthorization() async -> MicrophoneAuthorization
    func start() throws -> AsyncThrowingStream<PCMChunk, Error>
    func stop()
}

public protocol LocalDataKeyProviding {
    func loadKey(createIfMissing: Bool) throws -> Data
}

public enum MainDisposition: String, Codable, Sendable {
    case awaitingProcessing, completed, cancelled
}

public struct VoiceHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let recordedAt: Date
    public let sampleRate: Double
    public let frameCount: Int
    public var disposition: MainDisposition
    public var duration: TimeInterval { Double(frameCount) / sampleRate }
}

public enum RecordingState: Equatable, Sendable {
    case ready
    case requestingMicrophone
    case recording(id: UUID, duration: TimeInterval)
}

public enum DictationError: Error, Equatable, LocalizedError, Sendable {
    case microphoneUnavailable, alreadyRecording, noAudio, invalidAudio
    case dataKeyUnavailable, unreadableHistory, storageUnavailable, missingHistory
    case localStorageLimit, diskSpaceLow

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "麦克风未授权。请在系统设置中允许访问；历史和下载仍可使用。"
        case .alreadyRecording: "已有一段正在录音。"
        case .noAudio: "没有采集到有效音频，未创建历史记录。"
        case .invalidAudio: "音频格式无效，已停止录音。"
        case .dataKeyUnavailable: "无法取得本地数据密钥。原数据已保留，请恢复钥匙串访问。"
        case .unreadableHistory: "无法解密本地历史。原数据已保留，不会创建新密钥覆盖。"
        case .storageUnavailable: "无法安全保存音频，请检查磁盘和数据目录。"
        case .missingHistory: "找不到这条语音历史。"
        case .localStorageLimit: "本地数据已达到空间额度，请先导出或删除历史；原数据已保留。"
        case .diskSpaceLow: "真实磁盘空间不足，无法为录音和加密收尾保留安全余量。"
        }
    }
}

@MainActor
public final class RecordingApplication {
    public private(set) var state = RecordingState.ready
    public private(set) var notice: String?
    public var onChange: (() -> Void)?
    public var microphoneAuthorization: MicrophoneAuthorization { source.authorization }

    private let source: any AudioCapturing
    private let store: EncryptedHistory
    private var active: HistoryDraft?
    private var captureTask: Task<Void, Never>?
    private var cancelled = false
    private var generation = 0
    private var automaticStop = false
    private let limits: RecordingLimits
    private let now: () -> Date
    private let diskSpace: (URL) throws -> UInt64

    public init(source: any AudioCapturing, historyDirectory: URL, keys: any LocalDataKeyProviding,
                limits: RecordingLimits = RecordingLimits(), now: @escaping () -> Date = Date.init,
                diskSpace: @escaping (URL) throws -> UInt64 = { try FileSystemCapacity.availableBytes(at: $0) }) {
        self.source = source
        self.limits = limits
        self.now = now
        self.diskSpace = diskSpace
        store = EncryptedHistory(directory: historyDirectory, keys: keys)
    }

    @discardableResult
    public func startRecording() async -> Bool {
        guard state == .ready else { notify(DictationError.alreadyRecording.localizedDescription); return false }
        generation += 1
        let attempt = generation
        if source.authorization == .notDetermined {
            state = .requestingMicrophone
            onChange?()
            _ = await source.requestAuthorization()
        }
        guard generation == attempt else { return false }
        guard source.authorization == .authorized else {
            state = .ready
            notify(DictationError.microphoneUnavailable.localizedDescription)
            return false
        }
        do {
            guard limits.maximumDuration.isFinite, limits.maximumDuration > 0,
                  limits.maximumDuration <= 3_600 else { throw DictationError.invalidAudio }
            try requireCapacity(for: 32_768)
            let draft = try store.begin(at: now())
            active = draft
            cancelled = false
            automaticStop = false
            let audio = try source.start()
            state = .recording(id: draft.id, duration: 0)
            notice = nil
            onChange?()
            captureTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in audio {
                        guard !self.cancelled, !self.automaticStop else { continue }
                        guard chunk.sampleRate.isFinite, chunk.sampleRate >= 8_000, chunk.sampleRate <= 192_000 else {
                            throw DictationError.invalidAudio
                        }
                        let remainingFrames = max(0, Int(self.limits.maximumDuration * chunk.sampleRate) - draft.frameCount)
                        let accepted = PCMChunk(samples: Data(chunk.samples.prefix(remainingFrames * 2)), sampleRate: chunk.sampleRate)
                        if !accepted.samples.isEmpty {
                            do { try self.requireCapacity(for: UInt64(accepted.samples.count) + 34) }
                            catch {
                                self.stopAutomatically((error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription)
                                continue
                            }
                            try self.store.append(accepted, to: draft)
                        }
                        self.state = .recording(id: draft.id, duration: draft.duration)
                        self.onChange?()
                        if draft.duration >= self.limits.maximumDuration {
                            self.stopAutomatically("已达到单段录音时长上限，已录部分将保存到历史。")
                        }
                    }
                } catch {
                    self.notify((error as? DictationError)?.localizedDescription ?? "音频采集已中断。")
                    self.source.stop()
                }
                self.finish(draft)
            }
            return true
        } catch {
            if let active { try? store.discard(active) }
            active = nil
            state = .ready
            notify((error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription)
            return false
        }
    }

    public func finishRecording() async {
        guard active != nil else { return }
        source.stop()
        await captureTask?.value
    }

    public func cancelCurrentRecording() async {
        generation += 1
        cancelled = true
        if state == .requestingMicrophone {
            state = .ready
            onChange?()
        }
        guard active != nil else { return }
        source.stop()
        await captureTask?.value
    }

    public func checkRecordingConditions() {
        guard let active, !automaticStop else { return }
        if source.authorization != .authorized {
            stopAutomatically("麦克风权限已撤销，已录部分将保存到历史。")
        } else if now().timeIntervalSince(active.recordedAt) >= limits.maximumDuration {
            stopAutomatically("已达到单段录音时长上限，已录部分将保存到历史。")
        } else {
            do { try requireCapacity(for: 32_768) }
            catch { stopAutomatically((error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription) }
        }
    }

    public func history() throws -> [VoiceHistoryEntry] { try store.entries() }
    public func cancelRecordedSegment(_ id: UUID) throws {
        try store.setDisposition(.cancelled, for: id)
        onChange?()
    }

    public func completeMainDelivery(_ id: UUID) throws {
        try store.setDisposition(.completed, for: id)
        onChange?()
    }

    public func deleteHistory(_ id: UUID) throws {
        try store.delete(id)
        onChange?()
    }

    public func requestMicrophoneAccess() async {
        _ = await source.requestAuthorization()
        onChange?()
    }

    public func exportAudio(_ id: UUID, to destination: URL) throws {
        let audio = try store.waveAudio(id)
        try audio.write(to: destination, options: .atomic)
    }

    private func finish(_ draft: HistoryDraft) {
        do {
            if cancelled {
                try store.discard(draft)
                notice = "已取消当前录音，音频已丢弃。"
            } else if draft.frameCount == 0 {
                try store.discard(draft)
                notice = DictationError.noAudio.localizedDescription
            } else {
                try store.commit(draft)
                if notice == nil { notice = "录音已加密保存，可从语音历史下载。" }
            }
        } catch {
            notice = (error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription
        }
        active = nil
        captureTask = nil
        state = .ready
        onChange?()
    }

    private func notify(_ message: String) {
        notice = message
        onChange?()
    }

    private func stopAutomatically(_ message: String) {
        automaticStop = true
        notify(message)
        source.stop()
    }

    private func requireCapacity(for additionalBytes: UInt64) throws {
        // 留出的额度覆盖加密元数据及原子写入；真实磁盘余量另计。
        let finalizationReserve: UInt64 = 1_024 * 1_024
        let diskReserve: UInt64 = 64 * 1_024 * 1_024
        let used = try store.bytesOnDisk()
        guard used <= limits.maximumLocalBytes,
              additionalBytes <= limits.maximumLocalBytes - used,
              finalizationReserve <= limits.maximumLocalBytes - used - additionalBytes else {
            throw DictationError.localStorageLimit
        }
        let available = try diskSpace(store.directory)
        guard available >= diskReserve + finalizationReserve + additionalBytes else { throw DictationError.diskSpaceLow }
    }
}
