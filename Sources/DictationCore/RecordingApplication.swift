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
    public var recordingOrder: UInt64?
    public var queueStage: QueueStage?
    public var recordingEndedAt: Date?
    public var automaticSendingStartedAt: Date?
    public var polishedText: String?
    public var polish: PolishRecord?
    public var coach: CoachWorkUpdate?
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
    case retryUnavailable, deliveryUncertain, outOfOrderDelivery, applicationTerminating
    case pendingSegmentLimit, pendingDurationLimit, pendingAudioLimit, invalidQueueLimits
    case repolishUnavailable

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
        case .outOfOrderDelivery: "请先处理队头片段，再插入或确认这一段；复制不会放行队列。"
        case .applicationTerminating: "应用正在退出，未开始新的录音或处理。已有音频会保留。"
        case .pendingSegmentLimit: "主积压片段数已达到上限，请从队列处理或取消待交付片段。"
        case .pendingDurationLimit: "主积压累计音频时长已达到上限，已可靠保存的音频会保留。"
        case .pendingAudioLimit: "主积压音频已达到空间上限，已可靠保存的音频会保留。"
        case .invalidQueueLimits: "主积压额度无效，未开始录音。"
        case .repolishUnavailable: "需要已有原转写、可用润色客户端和未取消片段；已有润色工作不能重复发送。"
        }
    }
}

@MainActor
public struct CoachDependencies {
    let settings: CoachSettings
    let services: ServiceSettings
    let credentials: any ServiceCredentialStoring
    let networkConfiguration: URLSessionConfiguration
    let timing: any RequestTiming
    public init(settings: CoachSettings, services: ServiceSettings, credentials: any ServiceCredentialStoring,
                networkConfiguration: URLSessionConfiguration = .ephemeral, timing: any RequestTiming = ContinuousRequestTiming()) {
        self.settings = settings; self.services = services; self.credentials = credentials
        self.networkConfiguration = networkConfiguration; self.timing = timing
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
    public var polishReadiness: PolishReadiness { polishClient?.readiness ?? .disabled }
    public private(set) var coachScheduler: CoachWorkScheduler?
    public private(set) var coachConfigurationFailure: CoachFailure?
    public private(set) var coachFailure: CoachFailure?
    public var canDispatch: ((UUID) -> Bool)?

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
    private let polishClient: PolishClient?
    private let coachDependencies: CoachDependencies?
    private var coachIdentities: [UUID: CoachWorkIdentity] = [:]
    private var unsavedCoach: [UUID: CoachWorkUpdate] = [:]
    private var targets: [UUID: TextDeliveryTarget] = [:]
    private var attempts: [UUID: TranscriptionAttempt] = [:]
    private var transcriptionIdentities: [UUID: UUID] = [:]
    private struct PolishJob {
        let attemptID: UUID
        let automaticDelivery: Bool
        var attempt: PolishAttempt?
    }
    private var polishJobs: [UUID: PolishJob] = [:]
    private var unsavedPolish: [UUID: PolishRecord] = [:]
    private var autoEligible: Set<UUID> = []
    private var unsavedStates: [UUID: TranscriptionRecord] = [:]
    private var deliveryEligible: Set<UUID> = []
    private var requestSlots: [UUID: UUID] = [:]
    private var scheduling = false
    private var delivering = false
    private var terminating = false
    private var stoppingProcessing = false
    private var processingGeneration = UUID()
    private var invalidatingSegments: Set<UUID> = []
    private var deletingHistory: Set<UUID> = []
    private let queueLimits: QueueLimits
    private let processingSettings: ProcessingSettings
    private let resourceSettings: ResourceSettings
    public let mainRequestBudget = MainRequestBudget()
    public var processingConfiguration: ProcessingConfiguration { get throws { try processingSettings.load() } }

    public init(source: any AudioCapturing, historyDirectory: URL, keys: any LocalDataKeyProviding,
                limits: RecordingLimits = RecordingLimits(), now: @escaping () -> Date = Date.init,
                diskSpace: @escaping (URL) throws -> UInt64 = { try FileSystemCapacity.availableBytes(at: $0) },
                transcription: TranscriptionDependencies? = nil, queueLimits: QueueLimits = QueueLimits(),
                processingSettings: ProcessingSettings? = nil, polish: PolishClient? = nil, coach: CoachDependencies? = nil,
                resourceSettings: ResourceSettings? = nil) {
        self.source = source
        observedAuthorization = source.authorization
        self.limits = limits
        self.now = now
        self.diskSpace = diskSpace
        self.transcription = transcription
        self.polishClient = polish
        self.coachDependencies = coach
        self.queueLimits = queueLimits
        self.processingSettings = processingSettings ?? ProcessingSettings(file: historyDirectory.deletingLastPathComponent().appendingPathComponent("processing-settings.json"))
        self.resourceSettings = resourceSettings ?? ResourceSettings(file: historyDirectory.deletingLastPathComponent().appendingPathComponent("resource-settings.json"))
        store = EncryptedHistory(directory: historyDirectory, keys: keys)
        mainRequestBudget.onSlotAvailable = { [weak self] in self?.pumpProcessing() }
        if let config = try? self.processingSettings.load() { mainRequestBudget.updateLimit(config.maximumConcurrentMainRequests) }
        configureCoachIfNeeded()
    }

    private func configureCoachIfNeeded() {
        guard coachScheduler == nil, let dependencies = coachDependencies else { return }
        do {
            let scheduler = try CoachWorkScheduler(settings: dependencies.settings, services: dependencies.services,
                credentials: dependencies.credentials, networkConfiguration: dependencies.networkConfiguration, timing: dependencies.timing,
                canDispatch: { [weak self] identity in self?.mayDispatchCoach(identity) ?? false },
                onUpdate: { [weak self] update in
                    guard let self else { throw DictationError.applicationTerminating }
                    try self.persistCoach(update)
                })
            scheduler.onChange = { [weak self] in self?.onChange?() }
            coachScheduler = scheduler
            coachConfigurationFailure = nil
        } catch { coachConfigurationFailure = (error as? CoachFailure) ?? .invalidConfiguration }
    }

    private func mayDispatchCoach(_ identity: CoachWorkIdentity) -> Bool {
        guard !terminating, !stoppingProcessing, coachIdentities[identity.segmentID] == identity,
              let entry = try? store.entry(identity.segmentID), entry.disposition != .cancelled else { return false }
        guard entry.queueStage != .waitingForResume, entry.coach?.status != .waitingForResume else { return false }
        let generation = processingGeneration
        let allowed = withinAutomaticSendingWindow(entry) && (canDispatch?(identity.segmentID) ?? true)
        return allowed && generation == processingGeneration && !terminating && coachIdentities[identity.segmentID] == identity
    }

    private func persistCoach(_ update: CoachWorkUpdate) throws {
        let id = update.identity.segmentID
        guard !terminating, !stoppingProcessing, coachIdentities[id] == update.identity,
              let entry = try? store.entry(id), entry.disposition != .cancelled else { throw DictationError.missingHistory }
        do {
            try requireCapacity(for: UInt64(try JSONEncoder().encode(update).count * 4 + 65_536))
            guard !terminating, !stoppingProcessing, coachIdentities[id] == update.identity,
                  let current = try? store.entry(id), current.disposition != .cancelled else { throw DictationError.missingHistory }
            try store.updateEntry(id) { $0.coach = update }
            unsavedCoach[id] = nil
            coachFailure = update.failure
        } catch {
            if !terminating, !stoppingProcessing, coachIdentities[id] == update.identity,
               let current = try? store.entry(id), current.disposition != .cancelled {
                unsavedCoach[id] = CoachWorkUpdate(identity: update.identity, status: .failed,
                    dispatch: update.dispatch ?? current.coach?.dispatch, result: current.coach?.result, failure: .storageFailure)
                coachFailure = .storageFailure
            }
            throw error
        }
    }

    private func withinAutomaticSendingWindow(_ entry: VoiceHistoryEntry) -> Bool {
        do {
            return try !resourceSettings.load().isAutomaticSendingExpired(recordingEndedAt: entry.recordingEndedAt ?? entry.recordedAt,
                renewedAt: entry.automaticSendingStartedAt, now: now())
        } catch { notice = error.localizedDescription; return false }
    }

    @discardableResult
    public func startRecording() async -> Bool {
        guard !terminating else { notify(DictationError.applicationTerminating.localizedDescription); return false }
        guard state == .ready else { notify(DictationError.alreadyRecording.localizedDescription); return false }
        generation += 1
        let attempt = generation
        let target = transcription?.delivery.captureTarget()
        if source.authorization == .notDetermined {
            state = .requestingMicrophone
            onChange?()
            _ = await source.requestAuthorization()
        }
        guard generation == attempt, !terminating else {
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
            try requireQueueCapacityAtStart()
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
                        guard chunk.sampleRate.isFinite, chunk.sampleRate >= 8_000, chunk.sampleRate <= 192_000,
                              chunk.samples.count.isMultiple(of: 2), chunk.samples.count <= 1_048_576 else {
                            throw DictationError.invalidAudio
                        }
                        let usage = try self.queueUsage()
                        let durationRemaining = max(0, self.queueLimits.maximumPendingDuration - usage.duration)
                        let segmentFrames = max(0, Int(self.limits.maximumDuration * chunk.sampleRate) - draft.frameCount)
                        let durationFrames = Int(durationRemaining * chunk.sampleRate)
                        let bytesRemaining = self.queueLimits.maximumPendingAudioBytes > usage.audioBytes ? self.queueLimits.maximumPendingAudioBytes - usage.audioBytes : 0
                        // 每块为 GCM 头和文件分配留余量；保存后的实际占用仍再次检查。
                        let audioAllowance = bytesRemaining / 4_096 * 4_096
                        let byteFrames = audioAllowance > 34 ? Int(min(audioAllowance - 34, UInt64(Int.max))) / 2 : 0
                        let acceptedFrames = min(chunk.samples.count / 2, segmentFrames, durationFrames, byteFrames)
                        let accepted = PCMChunk(samples: Data(chunk.samples.prefix(acceptedFrames * 2)), sampleRate: chunk.sampleRate)
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
                        let savedUsage = try self.queueUsage()
                        if draft.duration >= self.limits.maximumDuration {
                            self.stopAutomatically("已达到单段录音时长上限，已录部分将保存到历史。")
                        } else if durationFrames <= chunk.samples.count / 2 {
                            self.stopAutomatically(DictationError.pendingDurationLimit.localizedDescription)
                        } else if byteFrames <= chunk.samples.count / 2 || savedUsage.audioBytes >= self.queueLimits.maximumPendingAudioBytes {
                            self.stopAutomatically(DictationError.pendingAudioLimit.localizedDescription)
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

    public func prepareForTermination() {
        guard !terminating else { return }
        terminating = true
        generation += 1
        if state == .requestingMicrophone { state = .ready }
        stopProcessing()
        if active != nil { source.stop() }
        onChange?()
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
            do {
                let usage = try queueUsage()
                if usage.duration >= queueLimits.maximumPendingDuration { throw DictationError.pendingDurationLimit }
                if usage.audioBytes >= queueLimits.maximumPendingAudioBytes { throw DictationError.pendingAudioLimit }
                try requireCapacity(for: 32_768)
            }
            catch { stopAutomatically((error as? DictationError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription) }
        }
    }

    public func history() throws -> [VoiceHistoryEntry] {
        let entries = try store.entries()
        let cutoff = now().addingTimeInterval(-30 * 86_400)
        let expired = entries.filter { $0.disposition != .awaitingProcessing && $0.recordedAt < cutoff }
        for entry in expired where !deletingHistory.contains(entry.id) { try deleteStoredHistory(entry.id) }
        let expiredIDs = Set(expired.map(\.id))
        return entries.filter { !expiredIDs.contains($0.id) }.map { entry in
            var displayed = entry
            if let unsaved = unsavedStates[entry.id] { displayed.transcription = unsaved }
            else if entry.transcription?.status == .inFlight, attempts[entry.id] == nil {
                displayed.transcription?.status = .interrupted
                displayed.transcription?.failure = .interruptedRequest
                displayed.queueStage = .interrupted
            }
            if let unsaved = unsavedPolish[entry.id] { displayed.polish = unsaved }
            else if entry.polish?.status == .inFlight, polishJobs[entry.id]?.attemptID != entry.polish?.attemptID {
                displayed.polish?.status = .interrupted
                displayed.polish?.failure = .interruptedRequest
                if displayed.disposition == .awaitingProcessing { displayed.queueStage = .interrupted }
            }
            if let unsaved = unsavedCoach[entry.id] { displayed.coach = unsaved }
            else if let coach = entry.coach, coach.status == .inFlight, coachIdentities[entry.id] != coach.identity {
                displayed.coach = CoachWorkUpdate(identity: coach.identity, status: .waitingForResume,
                    dispatch: coach.dispatch, result: coach.result, failure: nil)
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
            $0.queueStage = .cancelled
            if $0.polish?.status != .succeeded { $0.polish?.status = .cancelled; $0.polish?.failure = .cancelled }
            if let coach = $0.coach, coach.status != .succeeded {
                $0.coach = CoachWorkUpdate(identity: coach.identity, status: .cancelled,
                    dispatch: coach.dispatch, result: coach.result, failure: .cancelled)
            }
        }
        drainDelivery()
        onChange?()
    }

    public func completeMainDelivery(_ id: UUID) throws {
        invalidateMainProcessing(id)
        try store.updateEntry(id) { $0.disposition = .completed; $0.delivery = .skipped; $0.queueStage = .skipped }
        drainDelivery()
        onChange?()
    }

    public func deleteHistory(_ id: UUID) throws {
        try deleteStoredHistory(id)
        drainDelivery()
        onChange?()
    }

    private func deleteStoredHistory(_ id: UUID) throws {
        guard !deletingHistory.contains(id) else { throw DictationError.missingHistory }
        deletingHistory.insert(id)
        defer { deletingHistory.remove(id) }
        invalidateProcessing(id)
        try store.delete(id)
        unsavedStates[id] = nil; unsavedPolish[id] = nil; unsavedCoach[id] = nil
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

    public func currentText(_ id: UUID) throws -> String {
        let entry = try store.entry(id)
        guard let text = entry.polishedText ?? entry.rawTranscription else { throw DictationError.missingHistory }
        return text
    }

    public func copyCurrentText(_ id: UUID) throws { transcription?.delivery.copy(try currentText(id)) }

    public func exportPolishedText(_ id: UUID, to destination: URL) throws {
        try requireSafeExport(destination)
        guard let text = try store.entry(id).polishedText else { throw DictationError.missingHistory }
        try Data(text.utf8).write(to: destination, options: .atomic)
    }

    @discardableResult
    public func insertRawTranscriptionAtCurrentCursor(_ id: UUID) throws -> TextDeliveryResult {
        guard !terminating else { throw DictationError.applicationTerminating }
        return try insertAtCurrentCursor(id, text: rawTranscription(id))
    }

    @discardableResult
    public func insertCurrentTextAtCurrentCursor(_ id: UUID) throws -> TextDeliveryResult {
        guard !terminating else { throw DictationError.applicationTerminating }
        return try insertAtCurrentCursor(id, text: currentText(id))
    }

    private func insertAtCurrentCursor(_ id: UUID, text: String) throws -> TextDeliveryResult {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.retryUnavailable }
        let entry = try store.entry(id)
        try requireHead(id)
        guard entry.delivery != .uncertain else { throw DictationError.deliveryUncertain }
        guard entry.disposition == .awaitingProcessing, entry.rawTranscription != nil,
              let transcription else { throw DictationError.retryUnavailable }
        let generation = processingGeneration
        invalidateMainProcessing(id)
        // 释放请求槽会同步派发后段并通知观察者；撤销返回后，队头可能已取消或应用已停止。
        guard !terminating else { throw DictationError.applicationTerminating }
        guard generation == processingGeneration, !stoppingProcessing,
              !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.retryUnavailable }
        let current = try store.entry(id)
        try requireHead(id)
        guard current.disposition == .awaitingProcessing, current.delivery == entry.delivery,
              current.rawTranscription == entry.rawTranscription, current.polishedText == entry.polishedText else { throw DictationError.retryUnavailable }
        try store.updateEntry(id) { $0.delivery = .uncertain; $0.queueStage = .deliveryUncertain }
        guard !terminating else { throw DictationError.applicationTerminating }
        guard generation == processingGeneration, !stoppingProcessing,
              try store.entry(id).disposition == .awaitingProcessing else { throw DictationError.retryUnavailable }
        try requireHead(id)
        let result = transcription.delivery.insertAtCurrentCursor(text)
        let after = try store.entry(id)
        guard !terminating, generation == processingGeneration,
              after.disposition == .awaitingProcessing, after.delivery == .uncertain else { onChange?(); return result }
        try store.updateEntry(id) {
            $0.delivery = result == .delivered ? .delivered : result == .manual ? .manual : .uncertain
            $0.queueStage = result == .delivered ? .completed : result == .manual ? .awaitingManualDelivery : .deliveryUncertain
            if result == .delivered { $0.disposition = .completed }
        }
        if result == .delivered { drainDelivery() }
        onChange?()
        return result
    }

    public func confirmManuallyDelivered(_ id: UUID) throws {
        let entry = try store.entry(id)
        try requireHead(id)
        guard entry.disposition == .awaitingProcessing, entry.rawTranscription != nil else { throw DictationError.retryUnavailable }
        invalidateMainProcessing(id)
        try store.updateEntry(id) { $0.delivery = .delivered; $0.disposition = .completed; $0.queueStage = .completed }
        drainDelivery()
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
                try store.commit(draft, endedAt: now())
                if transcription != nil {
                    try store.updateEntry(draft.id) {
                        $0.transcription = TranscriptionRecord(status: .waitingForSlot)
                        $0.queueStage = .waitingForSlot
                    }
                    if !terminating { autoEligible.insert(draft.id) }
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
        if autoEligible.contains(draft.id) { pumpProcessing() }
        else if let target = targets.removeValue(forKey: draft.id) { transcription?.delivery.releaseTarget(target) }
    }

    private func invalidateMainProcessing(_ id: UUID) {
        let inserted = invalidatingSegments.insert(id).inserted
        defer { if inserted { invalidatingSegments.remove(id) } }
        let asrIdentity = transcriptionIdentities.removeValue(forKey: id)
        let asr = attempts.removeValue(forKey: id)
        let polish = polishJobs.removeValue(forKey: id)
        autoEligible.remove(id)
        deliveryEligible.remove(id)
        asr?.cancel()
        polish?.attempt?.cancel()
        if let asrIdentity { releaseSlot(asrIdentity) }
        if let polish { releaseSlot(polish.attemptID) }
        if let target = targets.removeValue(forKey: id) { transcription?.delivery.releaseTarget(target) }
    }

    private func invalidateProcessing(_ id: UUID) {
        let inserted = invalidatingSegments.insert(id).inserted
        defer { if inserted { invalidatingSegments.remove(id) } }
        coachIdentities[id] = nil
        invalidateMainProcessing(id)
        coachScheduler?.removeSegment(id)
    }

    private func releaseSlot(_ attemptID: UUID) {
        if let slot = requestSlots.removeValue(forKey: attemptID) { mainRequestBudget.release(slot) }
    }

    public func stopProcessing() {
        guard !stoppingProcessing else { return }
        stoppingProcessing = true
        defer { stoppingProcessing = false }
        processingGeneration = UUID()
        let asr = Array(attempts.values), polish = polishJobs.values.compactMap(\.attempt)
        attempts = [:]
        transcriptionIdentities = [:]
        polishJobs = [:]
        coachIdentities = [:]
        autoEligible = []
        deliveryEligible = []
        let held = Array(requestSlots.values)
        requestSlots = [:]
        asr.forEach { $0.cancel() }
        polish.forEach { $0.cancel() }
        coachScheduler?.stopProcessing()
        for slot in held { mainRequestBudget.release(slot) }
        for target in targets.values { transcription?.delivery.releaseTarget(target) }
        targets = [:]
    }

    public func configurationChanged() {
        guard !terminating, !stoppingProcessing else { return }
        configureCoachIfNeeded()
        if let scheduler = coachScheduler {
            do { try scheduler.configurationChanged(); coachConfigurationFailure = nil }
            catch { coachConfigurationFailure = (error as? CoachFailure) ?? .invalidConfiguration }
        }
        pumpProcessing()
        onChange?()
    }

    public func retryTranscription(_ id: UUID) throws {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.retryUnavailable }
        let entry = try store.entry(id)
        guard entry.disposition == .awaitingProcessing, entry.rawTranscription == nil,
              attempts[id] == nil else { throw DictationError.retryUnavailable }
        try store.updateEntry(id) {
            $0.transcription = TranscriptionRecord(status: .waitingForSlot); $0.queueStage = .waitingForSlot
            $0.automaticSendingStartedAt = now()
        }
        autoEligible.insert(id)
        unsavedStates[id] = nil
        pumpProcessing()
    }

    public func repolish(_ id: UUID) throws {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.repolishUnavailable }
        let entry = try store.entry(id)
        guard entry.disposition != .cancelled, entry.rawTranscription != nil, polishClient != nil,
              polishJobs[id] == nil else { throw DictationError.repolishUnavailable }
        try store.updateEntry(id) { $0.automaticSendingStartedAt = now() }
        deliveryEligible.remove(id)
        if let target = targets.removeValue(forKey: id) { transcription?.delivery.releaseTarget(target) }
        unsavedPolish[id] = nil
        polishJobs[id] = PolishJob(attemptID: UUID(), automaticDelivery: false)
        pumpProcessing()
    }

    public func resumePendingProcessing(_ id: UUID) throws {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.retryUnavailable }
        let entry = try store.entry(id)
        let mainPaused = entry.queueStage == .waitingForResume && (autoEligible.contains(id) || polishJobs[id] != nil)
        let coachPaused = entry.coach?.status == .waitingForResume && coachIdentities[id] == entry.coach?.identity
        guard entry.disposition != .cancelled, mainPaused || coachPaused else { throw DictationError.retryUnavailable }
        try store.updateEntry(id) {
            $0.automaticSendingStartedAt = now()
            if mainPaused { $0.queueStage = $0.rawTranscription == nil ? .waitingForSlot : .waitingForPolishSlot }
            if coachPaused, let coach = $0.coach {
                $0.coach = CoachWorkUpdate(identity: coach.identity, status: .queued, dispatch: coach.dispatch, result: coach.result, failure: nil)
            }
        }
        if mainPaused, entry.rawTranscription == nil { autoEligible.insert(id) }
        configurationChanged()
    }

    public func updateProcessingConfiguration(_ config: ProcessingConfiguration) throws {
        try processingSettings.save(config)
        mainRequestBudget.updateLimit(config.maximumConcurrentMainRequests)
        onChange?()
    }

    private func pumpProcessing() {
        guard !terminating, !stoppingProcessing, !scheduling else { return }
        let generation = processingGeneration
        scheduling = true
        defer { scheduling = false }
        do {
            let config = try processingSettings.load()
            mainRequestBudget.updateLimit(config.maximumConcurrentMainRequests)
            for entry in try store.entries().sorted(by: recordingPrecedes) {
                guard generation == processingGeneration, !terminating, !stoppingProcessing else { break }
                guard mainRequestBudget.activeCount < mainRequestBudget.limit else { break }
                let asrPending = autoEligible.contains(entry.id) && transcriptionIdentities[entry.id] == nil && entry.rawTranscription == nil
                let polishPending = polishJobs[entry.id]?.attempt == nil && polishJobs[entry.id] != nil
                guard asrPending || polishPending else { continue }
                let alreadyPaused = entry.queueStage == .waitingForResume
                let allowed = !alreadyPaused && withinAutomaticSendingWindow(entry) && (canDispatch?(entry.id) ?? true)
                guard generation == processingGeneration, !terminating,
                      autoEligible.contains(entry.id) || polishJobs[entry.id] != nil else { continue }
                guard allowed else {
                    try store.updateEntry(entry.id) { $0.queueStage = .waitingForResume }
                    continue
                }
                if asrPending {
                    let status = unsavedStates[entry.id]?.status ?? entry.transcription?.status
                    if status == .waitingForSlot || status == .waitingForConfiguration { dispatchTranscription(entry.id) }
                } else if polishPending { dispatchPolish(entry.id) }
            }
        } catch { notice = error.localizedDescription; onChange?() }
    }

    private func dispatchTranscription(_ id: UUID) {
        guard !terminating, !stoppingProcessing, let transcription, transcriptionIdentities[id] == nil,
              autoEligible.contains(id), let entry = try? store.entry(id), entry.disposition == .awaitingProcessing,
              entry.rawTranscription == nil, let slot = mainRequestBudget.acquire(for: .transcription) else { return }
        let attemptID = UUID(), generation = processingGeneration
        transcriptionIdentities[id] = attemptID
        requestSlots[attemptID] = slot
        var started = false
        defer {
            if !started {
                if transcriptionIdentities[id] == attemptID { transcriptionIdentities[id] = nil }
                releaseSlot(attemptID)
            }
        }
        do {
            let (service, role, key, timeout) = try currentTranscriptionService()
            guard let baseURL = URL(string: service.baseURL) else { throw TranscriptionFailure.invalidConfiguration }
            try requireCapacity(for: 4 * 256 * 1_024 + 65_536)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            let audio = try store.waveAudio(id)
            let record = TranscriptionRecord(status: .inFlight, attemptID: attemptID, serviceID: service.id, model: role.model)
            try store.updateEntry(id) { $0.transcription = record; $0.queueStage = .transcribing }
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
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
            started = true
            attempt.start()
        } catch {
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            let failure = (error as? TranscriptionFailure) ?? .storageFailure
            let waiting: Set<TranscriptionFailure> = [.missingConfiguration, .invalidConfiguration, .missingCredentials, .credentialsUnavailable]
            setTranscriptionFailure(failure, id: id, status: waiting.contains(failure) ? .waitingForConfiguration : .failed)
        }
        onChange?()
    }

    private func isCurrentTranscription(_ id: UUID, attemptID: UUID, generation: UUID) -> Bool {
        !terminating && !stoppingProcessing && processingGeneration == generation && transcriptionIdentities[id] == attemptID
            && (try? store.entry(id).disposition) == .awaitingProcessing
    }

    private func dispatchPolish(_ id: UUID) {
        guard let client = polishClient, let job = polishJobs[id], job.attempt == nil,
              let entry = try? store.entry(id), let raw = entry.rawTranscription, entry.disposition != .cancelled,
              let slot = mainRequestBudget.acquire(for: .polish) else { return }
        let attemptID = job.attemptID, generation = processingGeneration
        requestSlots[attemptID] = slot
        var started = false
        defer { if !started { releaseSlot(attemptID) } }
        do {
            let dispatch = try client.dispatch(rawTranscription: raw, attemptID: attemptID, beforeSend: { attempt in
                guard self.isCurrentPolish(id, attemptID: attemptID, generation: generation) else { throw ProcessingInvalidated() }
                try self.requireCapacity(for: 4 * 256 * 1_024 + 65_536)
                guard self.isCurrentPolish(id, attemptID: attemptID, generation: generation) else { throw ProcessingInvalidated() }
                try self.store.updateEntry(id) {
                    $0.polish = PolishRecord(status: .inFlight, attemptID: attemptID, serviceID: attempt.serviceID, model: attempt.model)
                    if job.automaticDelivery { $0.queueStage = .polishing }
                }
                guard self.isCurrentPolish(id, attemptID: attemptID, generation: generation) else { throw ProcessingInvalidated() }
                self.polishJobs[id]?.attempt = attempt
                self.unsavedPolish[id] = nil
            }, completed: { [weak self] completion in self?.receivePolish(completion, segmentID: id) })
            guard isCurrentPolish(id, attemptID: attemptID, generation: generation) else {
                if case .started(let attempt) = dispatch { attempt.cancel() }
                return
            }
            switch dispatch {
            case .started(let attempt):
                polishJobs[id]?.attempt = attempt
                started = true
            case .disabled:
                if job.automaticDelivery {
                    try store.updateEntry(id) { $0.delivery = .waiting; $0.queueStage = .waitingForPredecessor }
                    deliveryEligible.insert(id)
                }
                polishJobs[id] = nil
                drainDelivery()
            case .waiting(let failure):
                try store.updateEntry(id) {
                    $0.polish = PolishRecord(status: .waitingForConfiguration, attemptID: attemptID, failure: failure)
                    if job.automaticDelivery { $0.queueStage = .waitingForPolishConfiguration }
                }
                notice = failure.localizedDescription
            }
        } catch {
            guard isCurrentPolish(id, attemptID: attemptID, generation: generation) else { return }
            let failure = (error as? PolishFailure) ?? .storageFailure
            failPolishPersistence(id, attemptID: attemptID, failure: failure)
        }
        onChange?()
    }

    private func isCurrentPolish(_ id: UUID, attemptID: UUID, generation: UUID) -> Bool {
        guard !terminating, !stoppingProcessing, processingGeneration == generation,
              let job = polishJobs[id], job.attemptID == attemptID, let entry = try? store.entry(id), entry.disposition != .cancelled else { return false }
        return !job.automaticDelivery || entry.disposition == .awaitingProcessing
    }

    private struct ProcessingInvalidated: Error {}

    private func receivePolish(_ completion: PolishCompletion, segmentID id: UUID) {
        let generation = processingGeneration, attemptID = completion.attemptID
        guard isCurrentPolish(id, attemptID: attemptID, generation: generation), let job = polishJobs[id], job.attempt != nil,
              let entry = try? store.entry(id), entry.polish?.attemptID == attemptID else { return }
        defer {
            if polishJobs[id]?.attemptID == attemptID { polishJobs[id] = nil }
            releaseSlot(attemptID)
            onChange?()
        }
        do {
            let resultBytes: Int
            if case .success(let text) = completion.result { resultBytes = text.utf8.count }
            else { resultBytes = entry.rawTranscription?.utf8.count ?? 0 }
            try requireCapacity(for: UInt64(resultBytes * 4 + 65_536))
            guard isCurrentPolish(id, attemptID: attemptID, generation: generation) else { return }
            try store.updateEntry(id) {
                switch completion.result {
                case .success(let text):
                    $0.polishedText = text; $0.polish?.status = .succeeded; $0.polish?.failure = nil
                case .failure(let failure):
                    $0.polish?.status = failure == .timedOut ? .timedOut : .failed; $0.polish?.failure = failure
                }
                if job.automaticDelivery { $0.delivery = .waiting; $0.queueStage = .waitingForPredecessor }
            }
            guard isCurrentPolish(id, attemptID: attemptID, generation: generation) else { return }
            unsavedPolish[id] = nil
            polishJobs[id] = nil
            if job.automaticDelivery { deliveryEligible.insert(id); drainDelivery() }
            if case .failure(let failure) = completion.result {
                notice = failure.localizedDescription + (job.automaticDelivery ? " 该段以原转写作为当前候选。" : " 原转写与已有产物仍可从历史取用。")
            }
        } catch { failPolishPersistence(id, attemptID: attemptID, failure: .storageFailure) }
    }

    private func failPolishPersistence(_ id: UUID, attemptID: UUID, failure: PolishFailure) {
        guard polishJobs[id]?.attemptID == attemptID else { return }
        var record = (try? store.entry(id).polish) ?? PolishRecord(status: .failed, attemptID: attemptID)
        record.status = .failed; record.failure = failure
        polishJobs[id] = nil
        deliveryEligible.remove(id)
        do { try store.updateEntry(id) { $0.polish = record; if $0.disposition == .awaitingProcessing { $0.queueStage = .awaitingManualDelivery } }; unsavedPolish[id] = nil }
        catch { unsavedPolish[id] = record }
        notice = failure.localizedDescription
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
        let generation = processingGeneration
        guard isCurrentTranscription(id, attemptID: attemptID, generation: generation), let transcription,
              let attempt = attempts[id], attempt.id == attemptID,
              (try? store.entry(id).transcription?.attemptID) == attemptID else { return }
        defer {
            if attempts[id]?.id == attemptID { attempts[id] = nil }
            if transcriptionIdentities[id] == attemptID { transcriptionIdentities[id] = nil }
            releaseSlot(attemptID)
            onChange?()
        }
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
                guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
                try store.updateEntry(id) {
                    $0.transcription?.status = .succeeded; $0.transcription?.failure = nil
                    $0.rawTranscription = text; $0.delivery = .waiting
                    $0.queueStage = polishClient == nil ? .waitingForPredecessor : .waitingForPolishSlot
                }
                autoEligible.remove(id)
                if polishClient != nil { polishJobs[id] = PolishJob(attemptID: UUID(), automaticDelivery: true) }
                else { deliveryEligible.insert(id) }
            } catch { setTranscriptionFailure(.storageFailure, id: id, status: .failed); return }
            enqueueCoach(id, raw: text)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            pumpProcessing()
            drainDelivery()
        }
    }

    private func enqueueCoach(_ id: UUID, raw: String) {
        guard !terminating, !stoppingProcessing, let scheduler = coachScheduler,
              let entry = try? store.entry(id), entry.disposition != .cancelled else { return }
        let identity = CoachWorkIdentity(segmentID: id)
        coachIdentities[id] = identity
        do {
            if try !scheduler.enqueue(segmentID: id, rawText: raw, attemptID: identity.attemptID), coachIdentities[id] == identity {
                coachIdentities[id] = nil
            }
        } catch {
            if coachIdentities[id] == identity {
                coachIdentities[id] = nil
                notice = (error as? CoachFailure)?.localizedDescription ?? CoachFailure.storageFailure.localizedDescription
            }
        }
    }

    private func drainDelivery() {
        guard !terminating, !stoppingProcessing, !delivering, let transcription else { return }
        let generation = processingGeneration
        delivering = true
        defer { delivering = false }
        do {
            while let entry = try pendingEntries().first,
                  generation == processingGeneration, !terminating,
                  deliveryEligible.contains(entry.id), let text = entry.polishedText ?? entry.rawTranscription, entry.delivery == .waiting {
                let id = entry.id
                // 写之前先持久化不确定；崩溃或终态保存失败都不能自动再次插入。
                try store.updateEntry(id) { $0.delivery = .uncertain; $0.queueStage = .deliveryUncertain }
                deliveryEligible.remove(id)
                let result = targets[id].map { transcription.delivery.deliver(text, to: $0) } ?? .manual
                if let target = targets.removeValue(forKey: id) { transcription.delivery.releaseTarget(target) }
                let after = try store.entry(id)
                guard generation == processingGeneration, !terminating,
                      after.disposition == .awaitingProcessing, after.delivery == .uncertain else { continue }
                try store.updateEntry(id) {
                    $0.delivery = result == .delivered ? .delivered : result == .uncertain ? .uncertain : .manual
                    $0.queueStage = result == .delivered ? .completed : result == .uncertain ? .deliveryUncertain : .awaitingManualDelivery
                    if result == .delivered { $0.disposition = .completed }
                }
                notice = result == .delivered ? "文本已按口述顺序填入目标。" : result == .uncertain ? "写回结果无法确认，请检查目标并确认；后段等待。" : "目标变化或不可用，请手动处理队头；后段等待。"
                guard result == .delivered else { break }
            }
        } catch { notice = "队列交付状态无法安全保存。请检查目标；不会自动再次插入。" }
        onChange?()
    }

    private func setTranscriptionFailure(_ failure: TranscriptionFailure, id: UUID, status: TranscriptionStatus) {
        var record = (try? store.entry(id).transcription) ?? TranscriptionRecord(status: status)
        record.status = status
        record.failure = failure
        autoEligible.remove(id)
        if status == .waitingForConfiguration { autoEligible.insert(id) }
        do {
            try store.updateEntry(id) {
                $0.transcription = record
                $0.queueStage = status == .waitingForConfiguration ? .waitingForConfiguration : status == .timedOut ? .timedOut : .failed
            }
            unsavedStates[id] = nil
        }
        catch {
            record.status = .failed; record.failure = .storageFailure
            unsavedStates[id] = record
        }
        notice = (unsavedStates[id]?.failure ?? failure).localizedDescription
        onChange?()
    }

    public func skipMainDelivery(_ id: UUID) throws { try completeMainDelivery(id) }

    public func queue() throws -> [QueueSegment] {
        let entries = try history().filter { $0.disposition == .awaitingProcessing }.sorted(by: recordingPrecedes)
        var result = entries.enumerated().map { index, entry in
            let stage: QueueStage
            if entry.delivery == .uncertain { stage = .deliveryUncertain }
            else if entry.delivery == .manual { stage = .awaitingManualDelivery }
            else if polishJobs[entry.id] != nil { stage = entry.queueStage ?? .waitingForPolishSlot }
            else if entry.polish?.status == .interrupted { stage = .interrupted }
            else if entry.rawTranscription != nil, !deliveryEligible.contains(entry.id) { stage = .awaitingManualDelivery }
            else if entry.transcription?.status == .interrupted { stage = .interrupted }
            else if !autoEligible.contains(entry.id), entry.rawTranscription == nil,
                    entry.transcription?.status == .waitingForSlot || entry.transcription?.status == .waitingForConfiguration { stage = .interrupted }
            else if entry.transcription?.status == .failed { stage = .failed }
            else if entry.transcription?.status == .timedOut { stage = .timedOut }
            else { stage = entry.queueStage ?? .interrupted }
            let reason = stage == .waitingForResume ? "该段未发送的工作已暂停，主动恢复后开启新的等待时间窗；录音时间保持原样。"
                : entry.polish?.failure?.localizedDescription ?? entry.transcription?.failure?.localizedDescription ?? (stage == .waitingForPredecessor ? "前面的片段尚未终结，完成或明确处置队头后依序上屏。" : stage == .deliveryUncertain ? DictationError.deliveryUncertain.localizedDescription : stage == .awaitingManualDelivery ? "原目标已变化或无法可靠判断，请手动插入当前光标或确认已粘贴。" : nil)
            return QueueSegment(id: entry.id, recordingOrder: entry.recordingOrder, recordedAt: entry.recordedAt,
                duration: entry.duration, stage: stage, reason: reason, hasText: entry.rawTranscription != nil, isHead: index == 0)
        }
        if let active {
            result.append(QueueSegment(id: active.id, recordingOrder: active.recordingOrder, recordedAt: active.recordedAt,
                duration: active.duration, stage: .recording, reason: nil, hasText: false, isHead: result.isEmpty))
        }
        return result
    }

    public func queueUsage() throws -> QueueUsage {
        let pending = try pendingEntries()
        var duration = pending.reduce(0) { $0 + $1.duration }
        var bytes = try pending.reduce(UInt64(0)) { try $0 + store.audioBytes($1.id) }
        if let active { duration += active.duration; bytes += try store.audioBytes(active.id, active: true) }
        return QueueUsage(segments: pending.count + (active == nil ? 0 : 1), duration: duration, audioBytes: bytes)
    }

    private func pendingEntries() throws -> [VoiceHistoryEntry] {
        try store.entries().filter { $0.disposition == .awaitingProcessing }.sorted(by: recordingPrecedes)
    }

    private func recordingPrecedes(_ a: VoiceHistoryEntry, _ b: VoiceHistoryEntry) -> Bool {
        if let left = a.recordingOrder, let right = b.recordingOrder { return left < right }
        if a.recordingOrder == nil && b.recordingOrder != nil { return true }
        if a.recordingOrder != nil && b.recordingOrder == nil { return false }
        // 旧格式没有开始序号，保守置于新片段之前且不自动派发。
        if a.recordedAt != b.recordedAt { return a.recordedAt < b.recordedAt }
        return a.id.uuidString < b.id.uuidString
    }

    private func requireHead(_ id: UUID) throws {
        guard try pendingEntries().first?.id == id else { throw DictationError.outOfOrderDelivery }
    }

    private func requireQueueCapacityAtStart() throws {
        guard (1...100).contains(queueLimits.maximumPendingSegments), queueLimits.maximumPendingDuration.isFinite,
              queueLimits.maximumPendingDuration > 0, queueLimits.maximumPendingDuration <= 120 * 60,
              queueLimits.maximumPendingAudioBytes > 0, queueLimits.maximumPendingAudioBytes <= 2_048 * 1_024 * 1_024 else { throw DictationError.invalidQueueLimits }
        let used = try queueUsage()
        guard used.segments < queueLimits.maximumPendingSegments else { throw DictationError.pendingSegmentLimit }
        guard used.duration < queueLimits.maximumPendingDuration else { throw DictationError.pendingDurationLimit }
        guard used.audioBytes < queueLimits.maximumPendingAudioBytes,
              queueLimits.maximumPendingAudioBytes - used.audioBytes >= 4_096 else { throw DictationError.pendingAudioLimit }
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
