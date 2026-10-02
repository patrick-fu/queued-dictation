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
    public var transcription: TranscriptionRecord?
    public var rawTranscription: String?
    public var delivery: DeliveryStatus?
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
    case unsafeExportDestination
    case retryUnavailable, deliveryUncertain

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
        case .unsafeExportDestination: "请选择本机加密数据目录以外的位置下载，以免覆盖语音历史。"
        case .retryUnavailable: "该片段正在处理、已终结或已有原文，不能重新转写。请取用已有结果。"
        case .deliveryUncertain: "写回结果无法确认，请检查目标并确认已粘贴；不能自动或再次插入。"
        }
    }
}

@MainActor
public final class RecordingApplication {
    public private(set) var state = RecordingState.ready
    public private(set) var notice: String?
    public var onChange: (() -> Void)?
    public var microphoneAuthorization: MicrophoneAuthorization { source.authorization }
    public var transcriptionReadiness: TranscriptionFailure? {
        do { _ = try currentTranscriptionService(); return nil }
        catch { return (error as? TranscriptionFailure) ?? .invalidConfiguration }
    }

    private let source: any AudioCapturing
    private let store: EncryptedHistory
    private var active: HistoryDraft?
    private var captureTask: Task<Void, Never>?
    private var cancelled = false
    private var generation = 0
    private var automaticStop = false
    private var observedAuthorization: MicrophoneAuthorization
    private let limits: RecordingLimits
    private let now: () -> Date
    private let diskSpace: (URL) throws -> UInt64
    private let transcription: TranscriptionDependencies?
    private var targets: [UUID: TextDeliveryTarget] = [:]
    private var attempts: [UUID: TranscriptionAttempt] = [:]
    private var autoEligible: Set<UUID> = []
    private var unsavedStates: [UUID: TranscriptionRecord] = [:]

    public init(source: any AudioCapturing, historyDirectory: URL, keys: any LocalDataKeyProviding,
                limits: RecordingLimits = RecordingLimits(), now: @escaping () -> Date = Date.init,
                diskSpace: @escaping (URL) throws -> UInt64 = { try FileSystemCapacity.availableBytes(at: $0) },
                transcription: TranscriptionDependencies? = nil) {
        self.source = source
        observedAuthorization = source.authorization
        self.limits = limits
        self.now = now
        self.diskSpace = diskSpace
        self.transcription = transcription
        store = EncryptedHistory(directory: historyDirectory, keys: keys)
    }

    @discardableResult
    public func startRecording() async -> Bool {
        guard state == .ready else { notify(DictationError.alreadyRecording.localizedDescription); return false }
        generation += 1
        let attempt = generation
        let target = transcription?.delivery.captureTarget()
        if source.authorization == .notDetermined {
            state = .requestingMicrophone
            onChange?()
            _ = await source.requestAuthorization()
        }
        guard generation == attempt else {
            if let target { transcription?.delivery.releaseTarget(target) }
            return false
        }
        guard source.authorization == .authorized else {
            state = .ready
            if let target { transcription?.delivery.releaseTarget(target) }
            notify(DictationError.microphoneUnavailable.localizedDescription)
            return false
        }
        do {
            guard limits.maximumDuration.isFinite, limits.maximumDuration > 0,
                  limits.maximumDuration <= 3_600 else { throw DictationError.invalidAudio }
            _ = try history()
            try requireCapacity(for: 32_768)
            let draft = try store.begin(at: now())
            if let target { targets[draft.id] = target }
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
                            do { try self.requireCapacity(for: UInt64(accepted.samples.count) + 34 + 4_096) }
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
            if let target { transcription?.delivery.releaseTarget(target) }
            if let active { targets[active.id] = nil; try? store.discard(active) }
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
        if let transcription {
            let expired = attempts.filter { transcription.timing.instant >= $0.value.deadline }
            for (id, attempt) in expired {
                receiveTranscription(.failure(.timedOut), segmentID: id, attemptID: attempt.id)
            }
        }
        let authorization = source.authorization
        if authorization != observedAuthorization {
            observedAuthorization = authorization
            onChange?()
        }
        guard let active, !automaticStop else { return }
        if authorization != .authorized {
            stopAutomatically("麦克风权限已撤销，已录部分将保存到历史。")
        } else if now().timeIntervalSince(active.recordedAt) >= limits.maximumDuration {
            stopAutomatically("已达到单段录音时长上限，已录部分将保存到历史。")
        } else {
            do { try requireCapacity(for: 32_768) }
            catch { stopAutomatically((error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription) }
        }
    }

    public func history() throws -> [VoiceHistoryEntry] {
        let entries = try store.entries()
        let cutoff = now().addingTimeInterval(-30 * 86_400)
        let expired = entries.filter { $0.disposition != .awaitingProcessing && $0.recordedAt < cutoff }
        for entry in expired { invalidateProcessing(entry.id); try store.delete(entry.id); unsavedStates[entry.id] = nil }
        let expiredIDs = Set(expired.map(\.id))
        return entries.filter { !expiredIDs.contains($0.id) }.map { entry in
            var displayed = entry
            if let unsaved = unsavedStates[entry.id] { displayed.transcription = unsaved }
            else if entry.transcription?.status == .inFlight, attempts[entry.id] == nil {
                displayed.transcription?.status = .interrupted
                displayed.transcription?.failure = .interruptedRequest
            }
            return displayed
        }
    }
    public func cancelRecordedSegment(_ id: UUID) throws {
        _ = try store.entry(id)
        invalidateProcessing(id)
        try store.updateEntry(id) {
            $0.disposition = .cancelled
            $0.transcription?.status = .cancelled
        }
        onChange?()
    }

    public func completeMainDelivery(_ id: UUID) throws {
        invalidateProcessing(id)
        try store.setDisposition(.completed, for: id)
        onChange?()
    }

    public func deleteHistory(_ id: UUID) throws {
        invalidateProcessing(id)
        try store.delete(id)
        unsavedStates[id] = nil
        onChange?()
    }

    public func requestMicrophoneAccess() async {
        _ = await source.requestAuthorization()
        onChange?()
    }

    public func exportAudio(_ id: UUID, to destination: URL) throws {
        try requireSafeExport(destination)
        let audio = try store.waveAudio(id)
        try audio.write(to: destination, options: .atomic)
    }

    public func rawTranscription(_ id: UUID) throws -> String {
        guard let text = try store.entry(id).rawTranscription else { throw DictationError.missingHistory }
        return text
    }

    public func exportRawTranscription(_ id: UUID, to destination: URL) throws {
        try requireSafeExport(destination)
        try Data(rawTranscription(id).utf8).write(to: destination, options: .atomic)
    }

    public func copyRawTranscription(_ id: UUID) throws {
        transcription?.delivery.copy(try rawTranscription(id))
    }

    @discardableResult
    public func insertRawTranscriptionAtCurrentCursor(_ id: UUID) throws -> TextDeliveryResult {
        let entry = try store.entry(id)
        guard entry.delivery != .uncertain else { throw DictationError.deliveryUncertain }
        guard entry.disposition == .awaitingProcessing, let text = entry.rawTranscription,
              let transcription else { throw DictationError.retryUnavailable }
        try store.updateEntry(id) { $0.delivery = .uncertain }
        let result = transcription.delivery.insertAtCurrentCursor(text)
        try store.updateEntry(id) {
            $0.delivery = result == .delivered ? .delivered : result == .manual ? .manual : .uncertain
            if result == .delivered { $0.disposition = .completed }
        }
        onChange?()
        return result
    }

    public func confirmManuallyDelivered(_ id: UUID) throws {
        let entry = try store.entry(id)
        guard entry.disposition == .awaitingProcessing, entry.rawTranscription != nil else { throw DictationError.retryUnavailable }
        invalidateProcessing(id)
        try store.updateEntry(id) { $0.delivery = .delivered; $0.disposition = .completed }
        onChange?()
    }

    private func requireSafeExport(_ destination: URL) throws {
        let root = store.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let output = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard output != root, !output.hasPrefix(root + "/") else { throw DictationError.unsafeExportDestination }
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
                if transcription != nil {
                    autoEligible.insert(draft.id)
                    try store.updateEntry(draft.id) {
                        $0.transcription = TranscriptionRecord(status: .waitingForConfiguration)
                    }
                }
                if notice == nil { notice = "录音已加密保存，可从语音历史下载。" }
            }
        } catch {
            notice = (error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription
        }
        active = nil
        captureTask = nil
        state = .ready
        onChange?()
        if autoEligible.contains(draft.id) { dispatchTranscription(draft.id) }
        else if let target = targets.removeValue(forKey: draft.id) { transcription?.delivery.releaseTarget(target) }
    }

    private func invalidateProcessing(_ id: UUID) {
        attempts.removeValue(forKey: id)?.cancel()
        autoEligible.remove(id)
        if let target = targets.removeValue(forKey: id) { transcription?.delivery.releaseTarget(target) }
    }

    public func stopProcessing() {
        for attempt in attempts.values { attempt.cancel() }
        attempts = [:]
        autoEligible = []
        for target in targets.values { transcription?.delivery.releaseTarget(target) }
        targets = [:]
    }

    public func configurationChanged() {
        for id in autoEligible where attempts[id] == nil {
            let status = unsavedStates[id]?.status ?? (try? store.entry(id).transcription?.status)
            if status == .waitingForConfiguration { dispatchTranscription(id) }
        }
        onChange?()
    }

    public func retryTranscription(_ id: UUID) throws {
        let entry = try store.entry(id)
        guard entry.disposition == .awaitingProcessing, entry.rawTranscription == nil,
              attempts[id] == nil else { throw DictationError.retryUnavailable }
        autoEligible.insert(id)
        dispatchTranscription(id)
    }

    private func dispatchTranscription(_ id: UUID) {
        guard let transcription, attempts[id] == nil,
              let entry = try? store.entry(id), entry.disposition == .awaitingProcessing,
              entry.rawTranscription == nil else { return }
        do {
            let (service, role, key, timeout) = try currentTranscriptionService()
            guard let baseURL = URL(string: service.baseURL) else { throw TranscriptionFailure.invalidConfiguration }
            try requireCapacity(for: 4 * 256 * 1_024 + 65_536)
            let audio = try store.waveAudio(id)
            let attemptID = UUID()
            let record = TranscriptionRecord(status: .inFlight, attemptID: attemptID, serviceID: service.id, model: role.model)
            try store.updateEntry(id) { $0.transcription = record }
            let deadline = transcription.timing.instant + timeout
            let attempt = TranscriptionAttempt(id: attemptID, deadline: deadline,
                url: baseURL.appendingPathComponent("audio/transcriptions"), model: role.model, key: key,
                audio: audio, configuration: transcription.networkConfiguration) { [weak self] result in
                    Task { @MainActor in self?.receiveTranscription(result, segmentID: id, attemptID: attemptID) }
                }
            attempts[id] = attempt
            unsavedStates[id] = nil
            attempt.deadlineTask = Task { [weak self] in
                do { try await transcription.timing.wait(until: deadline) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.receiveTranscription(.failure(.timedOut), segmentID: id, attemptID: attemptID)
            }
            attempt.start()
        } catch {
            let failure = (error as? TranscriptionFailure) ?? .storageFailure
            let waiting: Set<TranscriptionFailure> = [.missingConfiguration, .invalidConfiguration, .missingCredentials, .credentialsUnavailable]
            setTranscriptionFailure(failure, id: id, status: waiting.contains(failure) ? .waitingForConfiguration : .failed)
        }
        onChange?()
    }

    private func currentTranscriptionService() throws -> (ModelService, ModelRoleConfiguration, String?, TimeInterval) {
        guard let transcription else { throw TranscriptionFailure.missingConfiguration }
        let config = try transcription.settings.load()
        guard let role = config.transcription,
              let service = config.services.first(where: { $0.id == role.serviceID }) else { throw TranscriptionFailure.missingConfiguration }
        var key: String?
        if service.authentication == .bearerToken {
            guard let value = try transcription.credentials.key(for: service.credentialID ?? service.id), !value.isEmpty,
                  value.utf8.count <= 8_192, !value.contains("\r"), !value.contains("\n") else {
                throw TranscriptionFailure.missingCredentials
            }
            key = value
        }
        return (service, role, key, config.transcriptionTimeout)
    }

    private func receiveTranscription(_ result: Result<String, TranscriptionFailure>, segmentID id: UUID, attemptID: UUID) {
        guard let transcription, let attempt = attempts[id], attempt.id == attemptID else { return }
        attempts[id] = nil
        if transcription.timing.instant >= attempt.deadline {
            attempt.cancel()
            setTranscriptionFailure(.timedOut, id: id, status: .timedOut)
            return
        }
        attempt.finish()
        switch result {
        case .failure(let failure):
            setTranscriptionFailure(failure, id: id, status: .failed)
        case .success(let text):
            do {
                try requireCapacity(for: UInt64(text.utf8.count * 4 + 65_536))
                try store.updateEntry(id) {
                    $0.transcription?.status = .succeeded
                    $0.transcription?.failure = nil
                    $0.rawTranscription = text
                    // 写之前先记为不确定，崩溃或保存终态失败不能再次自动插入。
                    $0.delivery = .uncertain
                }
                autoEligible.remove(id)
            } catch { setTranscriptionFailure(.storageFailure, id: id, status: .failed); return }
            let result = targets[id].map { transcription.delivery.deliver(text, to: $0) } ?? .manual
            do {
                try store.updateEntry(id) {
                    $0.delivery = result == .delivered ? .delivered : result == .uncertain ? .uncertain : .manual
                    if result == .delivered { $0.disposition = .completed }
                }
                notice = result == .delivered ? "转写已加密保存并填入目标。" : result == .uncertain ? "写回结果无法确认，请检查目标；不会自动再次插入。" : "转写已加密保存，目标变化或不可用，请从历史手动取用。"
            } catch { notice = "转写已保存，写回状态无法持久化。请检查目标；不会自动再次插入。" }
            if let target = targets.removeValue(forKey: id) { transcription.delivery.releaseTarget(target) }
            onChange?()
        }
    }

    private func setTranscriptionFailure(_ failure: TranscriptionFailure, id: UUID, status: TranscriptionStatus) {
        var record = (try? store.entry(id).transcription) ?? TranscriptionRecord(status: status)
        record.status = status
        record.failure = failure
        do { try store.updateEntry(id) { $0.transcription = record }; unsavedStates[id] = nil }
        catch {
            record.status = .failed; record.failure = .storageFailure
            unsavedStates[id] = record
        }
        notice = (unsavedStates[id]?.failure ?? failure).localizedDescription
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
