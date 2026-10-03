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
    public var interruptedRecording: Bool?
    public var duration: TimeInterval { Double(frameCount) / sampleRate }
}

public struct RecoveryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let interruptedRecording: Bool
    public let canResumeUnsent: Bool
    public let needsTranscriptionRetry: Bool
    public let needsPolishRetry: Bool
    public let needsCoachRetry: Bool
    public let deliveryUncertain: Bool
}

enum RecoveryFaultPoint: String {
    case formatCheckpoint, audioSaved, entrySavedBeforeMove
    case transcriptionInFlight, polishInFlight, coachInFlight
    case rawCommittedBeforeMemory, polishQueued, polishResultSaved, coachResultSaved
    case deliveryUncertain, deliveryPerformed
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
    public private(set) var recoveryNotice: String?
    public var onChange: (() -> Void)?
    var recoveryFault: ((RecoveryFaultPoint) -> Void)? {
        didSet { store.recoveryFault = recoveryFault }
    }
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
    private struct ASRPreparation {
        let attemptID: UUID
        let generation: UUID
        var task: Task<PreparedTranscriptionRequest, Error>?
        var ready: PreparedTranscriptionRequest?
    }
    private var asrPreparations: [UUID: ASRPreparation] = [:]
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
    private var checkingConditions = false
    private var processingGeneration = UUID()
    private var invalidatingSegments: Set<UUID> = []
    private var deletingHistory: Set<UUID> = []
    private let queueLimits: QueueLimits
    private let processingSettings: ProcessingSettings
    private let resourceSettings: ResourceSettings
    private let usesConfiguredLimits: Bool
    private let historyRetentionSettings: HistoryRetentionSettings
    private var historyExports: [UUID: (segmentID: UUID, operation: HistoryExportOperation)] = [:]
    private var recoveryComplete = false
    private var recovering = false
    private var recoveredIDs: Set<UUID> = []
    private var observedCoachEnabled: Bool?
    private var pendingRecoveredCoachLookups: Set<UUID> = []
    private var pendingRecoveredCoachCancellations: [UUID: CoachWorkIdentity] = [:]
    private var storageReservations: [UUID: UInt64] = [:]
    private let dispatchBackoff: DispatchBackoff
    public let mainRequestBudget = MainRequestBudget()
    public var processingConfiguration: ProcessingConfiguration { get throws { try processingSettings.load() } }

    public init(source: any AudioCapturing, historyDirectory: URL, keys: any LocalDataKeyProviding,
                limits: RecordingLimits = RecordingLimits(), now: @escaping () -> Date = Date.init,
                diskSpace: @escaping (URL) throws -> UInt64 = { try FileSystemCapacity.availableBytes(at: $0) },
                transcription: TranscriptionDependencies? = nil, queueLimits: QueueLimits = QueueLimits(),
                processingSettings: ProcessingSettings? = nil, polish: PolishClient? = nil, coach: CoachDependencies? = nil,
                resourceSettings: ResourceSettings? = nil, network: (any NetworkAvailabilityProviding)? = nil,
                historyRetentionSettings: HistoryRetentionSettings? = nil) {
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
        usesConfiguredLimits = resourceSettings != nil
        self.resourceSettings = resourceSettings ?? ResourceSettings(file: historyDirectory.deletingLastPathComponent().appendingPathComponent("resource-settings.json"))
        self.historyRetentionSettings = historyRetentionSettings ?? HistoryRetentionSettings(file: historyDirectory.deletingLastPathComponent().appendingPathComponent("history-retention-settings.json"))
        dispatchBackoff = DispatchBackoff(network: network ?? SystemNetworkAvailability(),
            timing: transcription?.timing ?? coach?.timing ?? ContinuousRequestTiming(), now: now)
        store = EncryptedHistory(directory: historyDirectory, keys: keys)
        dispatchBackoff.onReady = { [weak self] in self?.configurationChanged() }
        polish?.dispatchGate = { [weak self] service in
            guard let self, !self.terminating, !self.stoppingProcessing else { throw ProcessingInvalidated() }
            try self.dispatchBackoff.require(service)
            guard !self.terminating, !self.stoppingProcessing else { throw ProcessingInvalidated() }
        }
        mainRequestBudget.onSlotAvailable = { [weak self] in self?.pumpProcessing() }
        if let config = try? self.processingSettings.load() { mainRequestBudget.updateLimit(config.maximumConcurrentMainRequests) }
        configureCoachIfNeeded()
        do { try ensureRecovery() }
        catch {
            recoveryNotice = (error as? DictationError)?.localizedDescription ?? (error as? ResourceSettingsError)?.localizedDescription
                ?? "无法安全恢复本地工作；原数据已保留，请检查数据目录与密钥访问。"
            notice = recoveryNotice
        }
    }

    private func unsentTranscription(_ entry: VoiceHistoryEntry) -> Bool {
        entry.disposition == .awaitingProcessing && entry.rawTranscription == nil &&
            entry.transcription.map { [TranscriptionStatus.waitingForSlot, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff].contains($0.status) } == true
    }

    private func unsentPolish(_ entry: VoiceHistoryEntry) -> Bool {
        entry.disposition != .cancelled && entry.rawTranscription != nil &&
            entry.polish.map { [PolishStatus.waitingForSlot, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff].contains($0.status) } == true
    }

    private func unsentCoach(_ entry: VoiceHistoryEntry) -> Bool {
        entry.disposition != .cancelled && entry.rawTranscription != nil &&
            entry.coach.map { [CoachWorkStatus.queued, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff, .waitingForResume].contains($0.status) } == true
    }

    private func canResumeCoach(_ entry: VoiceHistoryEntry) -> Bool {
        unsentCoach(entry) && (try? coachDependencies?.settings.load().enabled) == true &&
            !pendingRecoveredCoachLookups.contains(entry.id) && pendingRecoveredCoachCancellations[entry.id] != entry.coach?.identity
    }

    private func ensureRecovery() throws {
        guard !recoveryComplete else { return }
        guard !recovering else { throw DictationError.storageUnavailable }
        recovering = true
        defer { recovering = false }
        let warnings = try store.recoverInterruptedRecordings(transcriptionRequested: transcription != nil, capacity: { try self.requireCapacity(for: $0) })
        let coachDisabled = coachDependencies.flatMap { try? $0.settings.load().enabled } == false
        for original in try store.entries() {
            var entry = original
            if entry.transcription?.status == .inFlight {
                entry.transcription?.status = .interrupted; entry.transcription?.failure = .interruptedRequest
            }
            if entry.polish?.status == .inFlight {
                entry.polish?.status = .interrupted; entry.polish?.failure = .interruptedRequest
            }
            if let coach = entry.coach, coach.status == .inFlight {
                entry.coach = CoachWorkUpdate(identity: coach.identity, status: .interrupted, dispatch: coach.dispatch,
                    result: coach.result, failure: .interruptedRequest)
            } else if let coach = entry.coach, unsentCoach(entry) {
                entry.coach = CoachWorkUpdate(identity: coach.identity, status: coachDisabled ? .cancelled : .waitingForResume,
                    dispatch: coach.dispatch, result: coach.result, failure: coachDisabled ? .cancelled : nil)
            }
            if entry.disposition == .awaitingProcessing {
                if entry.rawTranscription != nil {
                    if entry.delivery == .waiting || entry.delivery == .manual { entry.delivery = .manual }
                    else if entry.delivery == nil { entry.delivery = .uncertain }
                }
                if unsentTranscription(entry) || unsentPolish(entry) { entry.queueStage = .waitingForResume }
                else if entry.delivery == .uncertain { entry.queueStage = .deliveryUncertain }
                else if entry.rawTranscription != nil { entry.queueStage = .awaitingManualDelivery }
                else if entry.transcription != nil || entry.interruptedRecording == true { entry.queueStage = .interrupted }
            } else if unsentPolish(entry) { entry.queueStage = .waitingForResume }
            if entry != original {
                try store.updateEntry(entry.id, capacity: { try self.requireCapacity(for: $0) }) { $0 = entry }
            }
            if entry.disposition == .awaitingProcessing || unsentPolish(entry) || unsentCoach(entry) ||
                entry.polish.map({ [.interrupted, .failed, .timedOut].contains($0.status) }) == true ||
                entry.coach.map({ [.interrupted, .failed, .timedOut].contains($0.status) }) == true {
                recoveredIDs.insert(entry.id)
            }
        }
        recoveryComplete = true
        if !warnings.isEmpty { recoveryNotice = warnings.joined(separator: "\n") }
        else if !recoveredIDs.isEmpty { recoveryNotice = "重启后未完成工作已暂停；未知请求需显式重试，旧目标改为手动取用。" }
        notice = recoveryNotice
    }

    public func recoveryItems() throws -> [RecoveryItem] {
        try ensureRecovery()
        return try history().filter { recoveredIDs.contains($0.id) && $0.disposition != .cancelled }.compactMap { entry in
            let usable = !terminating && !stoppingProcessing && !invalidatingSegments.contains(entry.id) && !deletingHistory.contains(entry.id)
            let unsent = usable && (entry.queueStage == .waitingForResume && (unsentTranscription(entry) || unsentPolish(entry)) || entry.coach?.status == .waitingForResume && canResumeCoach(entry))
            let asr = usable && transcription != nil && entry.disposition == .awaitingProcessing && entry.rawTranscription == nil && !unsentTranscription(entry)
                && attempts[entry.id] == nil && asrPreparations[entry.id]?.task == nil && transcriptionIdentities[entry.id].flatMap { requestSlots[$0] } == nil
            let polish = usable && polishClient != nil && polishJobs[entry.id] == nil && entry.polish.map { [.interrupted, .failed, .timedOut].contains($0.status) } == true
            let coach = usable && coachScheduler?.containsWork(for: entry.id) != true && entry.coach.map { [.interrupted, .failed, .timedOut].contains($0.status) } == true
                && (try? coachDependencies?.settings.load().enabled) == true && !pendingRecoveredCoachLookups.contains(entry.id)
                && pendingRecoveredCoachCancellations[entry.id] != entry.coach?.identity
            guard unsent || asr || polish || coach || entry.disposition == .awaitingProcessing else { return nil }
            return RecoveryItem(id: entry.id, interruptedRecording: entry.interruptedRecording == true, canResumeUnsent: unsent,
                needsTranscriptionRetry: asr, needsPolishRetry: polish, needsCoachRetry: coach, deliveryUncertain: entry.delivery == .uncertain)
        }
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
            scheduler.dispatchGate = { [weak self] service in
                guard let self, !self.terminating, !self.stoppingProcessing else { throw ProcessingInvalidated() }
                try self.dispatchBackoff.require(service)
                guard !self.terminating, !self.stoppingProcessing else { throw ProcessingInvalidated() }
            }
            scheduler.waveForSegment = { [weak self] id in
                guard let self, !self.terminating, !self.stoppingProcessing,
                      let entry = try? self.store.entry(id), entry.disposition != .cancelled else { throw CoachFailure.audioUnavailable }
                return try self.store.wavePreparation(id)
            }
            scheduler.onRetryAfter = { [weak self] service, retryAfter in self?.dispatchBackoff.record(retryAfter, for: service) }
            scheduler.onChange = { [weak self] in self?.coachStateChanged() }
            coachScheduler = scheduler
            coachConfigurationFailure = nil
        } catch { coachConfigurationFailure = (error as? CoachFailure) ?? .invalidConfiguration }
    }

    private func coachStateChanged() {
        defer { onChange?() }
        guard recoveryComplete, let scheduler = coachScheduler, observedCoachEnabled != scheduler.configuration.enabled else { return }
        observedCoachEnabled = scheduler.configuration.enabled
        var failed = false
        if !scheduler.configuration.enabled {
            // 先记关闭意图；AES 暂不可读时尚不能证明角色身份，也不能把这次关闭丢掉。
            pendingRecoveredCoachLookups.formUnion(recoveredIDs.filter { !scheduler.containsWork(for: $0) })
        }
        for id in pendingRecoveredCoachLookups {
            do {
                let entry = try store.entry(id)
                if unsentCoach(entry), !scheduler.containsWork(for: id), let coach = entry.coach {
                    pendingRecoveredCoachCancellations[id] = coach.identity
                }
                pendingRecoveredCoachLookups.remove(id)
            } catch { failed = true }
        }
        // 失败的关闭写入只在下一次开关变化时再处理，相同 disabled 通知不能反复扫描或写 AES。
        for (id, identity) in pendingRecoveredCoachCancellations {
            do {
                let entry = try store.entry(id)
                guard entry.coach?.identity == identity, unsentCoach(entry), !scheduler.containsWork(for: id) else {
                    pendingRecoveredCoachCancellations[id] = nil
                    continue
                }
                try store.updateEntry(id) {
                    $0.coach = CoachWorkUpdate(identity: identity, status: .cancelled, dispatch: entry.coach?.dispatch,
                        result: entry.coach?.result, failure: .cancelled)
                }
                pendingRecoveredCoachCancellations[id] = nil
                unsavedCoach[id] = nil
            } catch { failed = true }
        }
        if failed { coachFailure = .storageFailure; notice = CoachFailure.storageFailure.localizedDescription }
    }

    private func mayDispatchCoach(_ identity: CoachWorkIdentity) -> Bool {
        guard !terminating, !stoppingProcessing, coachIdentities[identity.segmentID] == identity,
              let entry = try? store.entry(identity.segmentID), entry.disposition != .cancelled else { return false }
        guard entry.coach?.status != .waitingForResume, !pendingRecoveredCoachLookups.contains(identity.segmentID),
              pendingRecoveredCoachCancellations[identity.segmentID] != identity else { return false }
        let generation = processingGeneration
        let allowed = withinAutomaticSendingWindow(entry) && (canDispatch?(identity.segmentID) ?? true)
        return allowed && generation == processingGeneration && !terminating && coachIdentities[identity.segmentID] == identity
    }

    private func persistCoach(_ update: CoachWorkUpdate) throws {
        let id = update.identity.segmentID
        guard !terminating, !stoppingProcessing, coachIdentities[id] == update.identity,
              let entry = try? store.entry(id), entry.disposition != .cancelled else { throw DictationError.missingHistory }
        defer { if update.status != .inFlight { storageReservations[update.identity.attemptID] = nil } }
        do {
            if update.status == .inFlight {
                try reserveResultStorage(for: id, attemptID: update.identity.attemptID, maximumEncodedResult: 4 * (256 * 1_024 + 128 * 1_024))
            } else if update.status != .queued && update.status != .waitingForConfiguration && update.status != .waitingForNetwork && update.status != .waitingForBackoff && update.status != .waitingForResume {
                try requireCapacity(for: UInt64(try JSONEncoder().encode(update).count * 4 + 65_536), excluding: update.identity.attemptID)
            }
            guard !terminating, !stoppingProcessing, coachIdentities[id] == update.identity,
                  let current = try? store.entry(id), current.disposition != .cancelled else { throw DictationError.missingHistory }
            try store.updateEntry(id, capacity: { bytes in
                try self.requireCapacity(for: bytes, excluding: update.identity.attemptID)
                guard !self.terminating, !self.stoppingProcessing, self.coachIdentities[id] == update.identity,
                      let entry = try? self.store.entry(id), entry.disposition != .cancelled else { throw ProcessingInvalidated() }
            }) { $0.coach = update }
            if update.status == .inFlight { recoveryFault?(.coachInFlight) }
            else if update.status == .succeeded { recoveryFault?(.coachResultSaved) }
            unsavedCoach[id] = nil
            coachFailure = update.failure
        } catch {
            storageReservations[update.identity.attemptID] = nil
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
            let (limits, _) = try effectiveLimits()
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
                        let (limits, queueLimits) = try self.effectiveLimits()
                        let usage = try self.queueUsage()
                        if usage.segments > queueLimits.maximumPendingSegments {
                            self.stopAutomatically(DictationError.pendingSegmentLimit.localizedDescription)
                            continue
                        }
                        let durationRemaining = max(0, queueLimits.maximumPendingDuration - usage.duration)
                        let segmentFrames = max(0, Int(limits.maximumDuration * chunk.sampleRate) - draft.frameCount)
                        let durationFrames = Int(durationRemaining * chunk.sampleRate)
                        let bytesRemaining = queueLimits.maximumPendingAudioBytes > usage.audioBytes ? queueLimits.maximumPendingAudioBytes - usage.audioBytes : 0
                        // 每块为 GCM 头和文件分配留余量；保存后的实际占用仍再次检查。
                        let audioAllowance = bytesRemaining / 4_096 * 4_096
                        let byteFrames = audioAllowance > 34 ? Int(min(audioAllowance - 34, UInt64(Int.max))) / 2 : 0
                        let acceptedFrames = min(chunk.samples.count / 2, segmentFrames, durationFrames, byteFrames)
                        let accepted = PCMChunk(samples: Data(chunk.samples.prefix(acceptedFrames * 2)), sampleRate: chunk.sampleRate)
                        if !accepted.samples.isEmpty {
                            do { try self.requireCapacity(for: UInt64(accepted.samples.count) + 34 + 4_096) }
                            catch {
                                self.stopAutomatically((error as? DictationError)?.localizedDescription ?? (error as? ResourceSettingsError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription)
                                continue
                            }
                            try self.store.append(accepted, to: draft)
                        }
                        self.state = .recording(id: draft.id, duration: draft.duration)
                        self.onChange?()
                        let savedUsage = try self.queueUsage()
                        if draft.duration >= limits.maximumDuration {
                            self.stopAutomatically("已达到单段录音时长上限，已录部分将保存到历史。")
                        } else if durationFrames <= chunk.samples.count / 2 {
                            self.stopAutomatically(DictationError.pendingDurationLimit.localizedDescription)
                        } else if byteFrames <= chunk.samples.count / 2 || savedUsage.audioBytes >= queueLimits.maximumPendingAudioBytes {
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
            notify((error as? DictationError)?.localizedDescription ?? (error as? ResourceSettingsError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription)
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
        guard !checkingConditions else { return }
        checkingConditions = true
        defer { checkingConditions = false }
        if !terminating, !stoppingProcessing { pumpProcessing() }
        if let transcription {
            let expired = attempts.filter { transcription.timing.instant >= $0.value.deadline }
            for (id, attempt) in expired {
                receiveTranscription(.failure(.timedOut), segmentID: id, attemptID: attempt.id)
            }
        }
        if !terminating, !stoppingProcessing, let scheduler = coachScheduler {
            do { try scheduler.configurationChanged(); coachConfigurationFailure = nil } catch { coachConfigurationFailure = (error as? CoachFailure) ?? .invalidConfiguration }
        }
        let authorization = source.authorization
        if authorization != observedAuthorization {
            observedAuthorization = authorization
            onChange?()
        }
        guard let active, !automaticStop else { return }
        if authorization != .authorized {
            stopAutomatically("麦克风权限已撤销，已录部分将保存到历史。")
        } else {
            do {
                let (limits, queueLimits) = try effectiveLimits()
                if now().timeIntervalSince(active.recordedAt) >= limits.maximumDuration || active.duration >= limits.maximumDuration {
                    stopAutomatically("已达到单段录音时长上限，已录部分将保存到历史。")
                    return
                }
                let usage = try queueUsage()
                if usage.segments > queueLimits.maximumPendingSegments { throw DictationError.pendingSegmentLimit }
                if usage.duration >= queueLimits.maximumPendingDuration { throw DictationError.pendingDurationLimit }
                if usage.audioBytes >= queueLimits.maximumPendingAudioBytes { throw DictationError.pendingAudioLimit }
                try requireCapacity(for: 32_768)
            }
            catch { stopAutomatically((error as? DictationError)?.localizedDescription ?? (error as? ResourceSettingsError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription) }
        }
    }

    public func history() throws -> [VoiceHistoryEntry] {
        try ensureRecovery()
        let entries = try store.entries()
        let period = try historyRetentionSettings.load()
        let expired = stoppingProcessing || !deletingHistory.isEmpty ? [] : entries.filter {
            period.shouldExpire(recordedAt: $0.recordedAt, now: now(),
                isTerminal: $0.disposition != .awaitingProcessing, hasActiveRequest: hasUnfinishedHistoryWork($0))
        }
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
                displayed.coach = CoachWorkUpdate(identity: coach.identity, status: .interrupted,
                    dispatch: coach.dispatch, result: coach.result, failure: .interruptedRequest)
            }
            return displayed
        }
    }

    private func hasUnfinishedHistoryWork(_ entry: VoiceHistoryEntry) -> Bool {
        if attempts[entry.id] != nil || asrPreparations[entry.id] != nil || polishJobs[entry.id] != nil ||
            unsavedStates[entry.id] != nil || unsavedPolish[entry.id] != nil || unsavedCoach[entry.id] != nil ||
            historyExports.values.contains(where: { $0.segmentID == entry.id }) { return true }
        if let polish = entry.polish, [PolishStatus.waitingForSlot, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff, .inFlight, .interrupted].contains(polish.status) { return true }
        if let coach = entry.coach, [CoachWorkStatus.queued, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff, .waitingForResume, .inFlight, .interrupted].contains(coach.status) { return true }
        return false
    }

    public func availableHistoryExports(_ id: UUID) throws -> [HistoryExportItem] {
        let entry = try store.entry(id)
        var items: [HistoryExportItem] = entry.frameCount > 0 ? [.audio] : []
        if entry.rawTranscription?.isEmpty == false { items.append(.rawTranscription) }
        if entry.polishedText?.isEmpty == false { items.append(.polishedText) }
        if entry.coach?.result != nil { items.append(.coachResult) }
        return items
    }

    public func exportHistoryItem(_ item: HistoryExportItem, for id: UUID, to destination: URL) async throws {
        try await exportHistory(id, item: item, destination: destination)
    }

    public func exportHistoryZIP(_ id: UUID, to destination: URL) async throws {
        try await exportHistory(id, item: nil, destination: destination)
    }

    private func exportHistory(_ id: UUID, item: HistoryExportItem?, destination: URL) async throws {
        guard !terminating, !stoppingProcessing else { throw DictationError.applicationTerminating }
        try requireSafeExport(destination)
        let entry = try store.entry(id)
        if let item, try !availableHistoryExports(id).contains(item) { throw HistoryExportError.unavailableItem }
        let wave = item == nil || item == .audio ? try store.wavePreparation(id) : nil
        let operation = try HistoryExportOperation(destination: destination, vault: store.directory), operationID = UUID(), vault = store.directory
        historyExports[operationID] = (id, operation)
        defer { historyExports[operationID] = nil }
        let worker = Task.detached(priority: .userInitiated) {
            let snapshot = HistoryExportSnapshot(audio: try wave?.read(), rawTranscription: entry.rawTranscription,
                polishedText: entry.polishedText, coachResult: entry.coach?.result)
            let data = try item.map { try HistoryExporter.encodedItem($0, from: snapshot) } ?? HistoryExporter.encodedZIP(snapshot)
            try operation.write(data, to: destination, vault: vault)
        }
        operation.attach(worker)
        try await withTaskCancellationHandler { try await worker.value } onCancel: { operation.cancel() }
    }

    public func clearHistory() throws {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing else { return }
        stoppingProcessing = true
        defer { stoppingProcessing = false }
        for entry in try store.entries() { try deleteStoredHistory(entry.id) }
        drainDelivery()
        onChange?()
    }

    public func favoriteSnapshot(for card: CoachCard) throws -> FavoriteFeedback {
        let entry = try store.entry(card.id)
        guard let coach = entry.coach, coach.status == .succeeded, coach.identity == card.identity,
              coach.dispatch?.inputMode == card.inputMode, entry.rawTranscription == card.rawText,
              coach.result == .card(card.feedback), unsavedCoach[card.id] == nil else { throw FavoritesError.invalidSnapshot }
        return try favoriteSnapshot(for: card.id)
    }

    public func favoriteSnapshot(for id: UUID) throws -> FavoriteFeedback {
        let entry = try store.entry(id)
        guard let coach = entry.coach, coach.status == .succeeded, coach.identity.segmentID == id,
              let raw = entry.rawTranscription, case .card(let feedback) = coach.result,
              unsavedCoach[id] == nil else { throw FavoritesError.invalidSnapshot }
        return FavoriteFeedback(id: coach.identity.attemptID, createdAt: now(), sourceSegmentID: id,
            rawText: raw, polishedText: entry.polishedText, feedback: feedback)
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
        unsavedStates[id] = nil; unsavedPolish[id] = nil; unsavedCoach[id] = nil
        drainDelivery()
        onChange?()
    }

    public func completeMainDelivery(_ id: UUID) throws {
        invalidateMainProcessing(id)
        try store.updateEntry(id) {
            $0.disposition = .completed; $0.delivery = .skipped; $0.queueStage = .skipped
            self.finishMainRoleRecords(&$0)
        }
        unsavedStates[id] = nil; unsavedPolish[id] = nil
        drainDelivery()
        onChange?()
    }

    private func finishMainRoleRecords(_ entry: inout VoiceHistoryEntry) {
        if let status = entry.transcription?.status, [TranscriptionStatus.waitingForSlot, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff, .inFlight, .interrupted].contains(status) { entry.transcription?.status = .cancelled }
        if let status = entry.polish?.status, [PolishStatus.waitingForSlot, .waitingForConfiguration, .waitingForNetwork, .waitingForBackoff, .inFlight, .interrupted].contains(status) { entry.polish?.status = .cancelled }
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
        recoveredIDs.remove(id)
        pendingRecoveredCoachLookups.remove(id)
        pendingRecoveredCoachCancellations[id] = nil
    }

    public func requestMicrophoneAccess() async {
        _ = await source.requestAuthorization()
        onChange?()
    }

    public func exportAudio(_ id: UUID, to destination: URL) throws {
        do {
            let output = try LocalExportFile(destination: destination, vault: store.directory)
            let audio = try store.waveAudio(id)
            try output.write(audio); try output.commit()
        } catch LocalExportError.unsafeDestination { throw DictationError.unsafeExportDestination }
        catch LocalExportError.cannotWrite { throw HistoryExportError.cannotWrite }
    }

    public func rawTranscription(_ id: UUID) throws -> String {
        guard let text = try store.entry(id).rawTranscription else { throw DictationError.missingHistory }
        return text
    }

    public func exportRawTranscription(_ id: UUID, to destination: URL) throws {
        do {
            let output = try LocalExportFile(destination: destination, vault: store.directory)
            let text = try rawTranscription(id)
            try output.write(Data(text.utf8)); try output.commit()
        } catch LocalExportError.unsafeDestination { throw DictationError.unsafeExportDestination }
        catch LocalExportError.cannotWrite { throw HistoryExportError.cannotWrite }
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
        do {
            let output = try LocalExportFile(destination: destination, vault: store.directory)
            guard let text = try store.entry(id).polishedText else { throw DictationError.missingHistory }
            try output.write(Data(text.utf8)); try output.commit()
        } catch LocalExportError.unsafeDestination { throw DictationError.unsafeExportDestination }
        catch LocalExportError.cannotWrite { throw HistoryExportError.cannotWrite }
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
        try store.updateEntry(id) {
            $0.delivery = .uncertain; $0.queueStage = .deliveryUncertain
            self.finishMainRoleRecords(&$0)
        }
        recoveryFault?(.deliveryUncertain)
        guard !terminating else { throw DictationError.applicationTerminating }
        guard generation == processingGeneration, !stoppingProcessing,
              try store.entry(id).disposition == .awaitingProcessing else { throw DictationError.retryUnavailable }
        try requireHead(id)
        let result = transcription.delivery.insertAtCurrentCursor(text)
        recoveryFault?(.deliveryPerformed)
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
        try store.updateEntry(id) {
            $0.delivery = .delivered; $0.disposition = .completed; $0.queueStage = .completed
            self.finishMainRoleRecords(&$0)
        }
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
                try store.commit(draft, endedAt: now(), transcriptionRequested: transcription != nil)
                if transcription != nil {
                    if !terminating { autoEligible.insert(draft.id) }
                }
                if notice == nil { notice = "录音已加密保存，可从语音历史下载。" }
            }
        } catch {
            notice = (error as? DictationError)?.localizedDescription ?? (error as? ResourceSettingsError)?.localizedDescription ?? DictationError.storageUnavailable.localizedDescription
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
        let preparation = asrPreparations.removeValue(forKey: id)
        let polish = polishJobs.removeValue(forKey: id)
        autoEligible.remove(id)
        deliveryEligible.remove(id)
        asr?.cancel()
        preparation?.task?.cancel()
        polish?.attempt?.cancel()
        if let asrIdentity { releaseSlot(asrIdentity) }
        if let polish { releaseSlot(polish.attemptID) }
        if let target = targets.removeValue(forKey: id) { transcription?.delivery.releaseTarget(target) }
    }

    private func invalidateProcessing(_ id: UUID) {
        for item in historyExports.values where item.segmentID == id { item.operation.cancel() }
        if let identity = coachIdentities[id] { storageReservations[identity.attemptID] = nil }
        let inserted = invalidatingSegments.insert(id).inserted
        defer { if inserted { invalidatingSegments.remove(id) } }
        coachIdentities[id] = nil
        invalidateMainProcessing(id)
        coachScheduler?.removeSegment(id)
    }

    private func releaseSlot(_ attemptID: UUID) {
        storageReservations[attemptID] = nil
        releaseBudgetSlot(attemptID)
    }

    private func releaseBudgetSlot(_ attemptID: UUID) {
        if let slot = requestSlots.removeValue(forKey: attemptID) { mainRequestBudget.release(slot) }
    }

    public func stopProcessing() {
        guard !stoppingProcessing else { return }
        stoppingProcessing = true
        defer { stoppingProcessing = false }
        processingGeneration = UUID()
        for item in historyExports.values { item.operation.cancel() }
        dispatchBackoff.stopWakeups()
        storageReservations = [:]
        let asr = Array(attempts.values), polish = polishJobs.values.compactMap(\.attempt)
        let preparations = asrPreparations.values.compactMap(\.task)
        attempts = [:]
        asrPreparations = [:]
        transcriptionIdentities = [:]
        polishJobs = [:]
        coachIdentities = [:]
        autoEligible = []
        deliveryEligible = []
        let held = Array(requestSlots.values)
        requestSlots = [:]
        asr.forEach { $0.cancel() }
        preparations.forEach { $0.cancel() }
        polish.forEach { $0.cancel() }
        coachScheduler?.stopProcessing()
        for slot in held { mainRequestBudget.release(slot) }
        for target in targets.values { transcription?.delivery.releaseTarget(target) }
        targets = [:]
    }

    public func configurationChanged() {
        guard !terminating, !stoppingProcessing else { return }
        configureCoachIfNeeded()
        checkRecordingConditions()
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
              attempts[id] == nil, asrPreparations[id]?.task == nil,
              transcriptionIdentities[id].flatMap({ requestSlots[$0] }) == nil else { throw DictationError.retryUnavailable }
        let generation = processingGeneration
        invalidatingSegments.insert(id)
        defer { invalidatingSegments.remove(id) }
        autoEligible.remove(id)
        cancelPreparation(id)
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, generation == processingGeneration, !deletingHistory.contains(id),
              let current = try? store.entry(id), current.disposition == .awaitingProcessing,
              current.rawTranscription == nil else { throw DictationError.retryUnavailable }
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
        let attemptID = UUID()
        try store.updateEntry(id) {
            $0.automaticSendingStartedAt = now()
            $0.queueStage = .waitingForPolishSlot
            $0.polish = PolishRecord(status: .waitingForSlot, attemptID: attemptID)
        }
        recoveryFault?(.polishQueued)
        deliveryEligible.remove(id)
        if let target = targets.removeValue(forKey: id) { transcription?.delivery.releaseTarget(target) }
        unsavedPolish[id] = nil
        polishJobs[id] = PolishJob(attemptID: attemptID, automaticDelivery: false)
        pumpProcessing()
    }

    public func retryCoach(_ id: UUID) throws {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.retryUnavailable }
        let generation = processingGeneration
        configureCoachIfNeeded()
        guard let scheduler = coachScheduler, !scheduler.containsWork(for: id),
              try coachDependencies?.settings.load().enabled == true else { throw DictationError.retryUnavailable }
        let entry = try store.entry(id)
        guard entry.disposition != .cancelled, let raw = entry.rawTranscription, let previous = entry.coach,
              previous.status != .succeeded, previous.result == nil,
              CoachInputLanguage.inferred(from: raw) != .clearlyNonEnglish, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationError.retryUnavailable }
        let identity = CoachWorkIdentity(segmentID: id)
        try store.updateEntry(id, capacity: { bytes in
            try self.requireCapacity(for: bytes)
            guard !self.terminating, !self.stoppingProcessing, generation == self.processingGeneration,
                  !scheduler.containsWork(for: id), let current = try? self.store.entry(id),
                  current.disposition != .cancelled, current.coach == previous, current.rawTranscription == raw else { throw ProcessingInvalidated() }
        }) {
            $0.automaticSendingStartedAt = now()
            $0.coach = CoachWorkUpdate(identity: identity, status: .queued, dispatch: nil, result: nil, failure: nil)
        }
        guard !terminating, !stoppingProcessing, generation == processingGeneration,
              (try? store.entry(id).coach?.identity) == identity else { throw DictationError.retryUnavailable }
        unsavedCoach[id] = nil
        pendingRecoveredCoachLookups.remove(id)
        pendingRecoveredCoachCancellations[id] = nil
        enqueueCoach(id, raw: raw)
        onChange?()
    }

    public func resumePendingProcessing(_ id: UUID) throws {
        guard !terminating else { throw DictationError.applicationTerminating }
        guard !stoppingProcessing, !invalidatingSegments.contains(id), !deletingHistory.contains(id) else { throw DictationError.retryUnavailable }
        let entry = try store.entry(id)
        let mainPaused = entry.queueStage == .waitingForResume && (unsentTranscription(entry) || unsentPolish(entry))
        let coachPaused = entry.coach?.status == .waitingForResume && canResumeCoach(entry)
        guard entry.disposition != .cancelled, mainPaused || coachPaused else { throw DictationError.retryUnavailable }
        let polishID = entry.polish?.attemptID ?? UUID()
        try store.updateEntry(id) {
            $0.automaticSendingStartedAt = now()
            if mainPaused { $0.queueStage = $0.rawTranscription == nil ? .waitingForSlot : .waitingForPolishSlot }
            if mainPaused, unsentPolish(entry) { $0.polish = PolishRecord(status: .waitingForSlot, attemptID: polishID) }
            if coachPaused, let coach = $0.coach {
                $0.coach = CoachWorkUpdate(identity: coach.identity, status: .queued, dispatch: coach.dispatch, result: coach.result, failure: nil)
            }
        }
        if mainPaused, entry.rawTranscription == nil { autoEligible.insert(id) }
        if mainPaused, unsentPolish(entry), polishJobs[id] == nil {
            polishJobs[id] = PolishJob(attemptID: polishID, automaticDelivery: !recoveredIDs.contains(id) && entry.disposition == .awaitingProcessing)
        }
        if coachPaused, let raw = entry.rawTranscription, coachIdentities[id] != entry.coach?.identity { enqueueCoach(id, raw: raw) }
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
                let asrPending = autoEligible.contains(entry.id) && attempts[entry.id] == nil && entry.rawTranscription == nil
                let polishPending = polishJobs[entry.id]?.attempt == nil && polishJobs[entry.id] != nil
                guard asrPending || polishPending else { continue }
                let alreadyPaused = entry.queueStage == .waitingForResume
                let allowed = !alreadyPaused && withinAutomaticSendingWindow(entry) && (canDispatch?(entry.id) ?? true)
                guard generation == processingGeneration, !terminating,
                      autoEligible.contains(entry.id) || polishJobs[entry.id] != nil else { continue }
                guard allowed else {
                    try store.updateEntry(entry.id) { $0.queueStage = .waitingForResume }
                    cancelPreparation(entry.id)
                    continue
                }
                if asrPreparations[entry.id]?.task != nil { continue }
                guard mainRequestBudget.activeCount < mainRequestBudget.limit else { continue }
                if asrPending {
                    let status = unsavedStates[entry.id]?.status ?? entry.transcription?.status
                    if status == .waitingForSlot || status == .waitingForConfiguration || status == .waitingForNetwork || status == .waitingForBackoff {
                        if asrPreparations[entry.id]?.ready != nil { dispatchPreparedTranscription(entry.id) }
                        else if asrPreparations.count < mainRequestBudget.limit { dispatchTranscription(entry.id) }
                    }
                } else if polishPending { dispatchPolish(entry.id) }
            }
        } catch { notice = error.localizedDescription; onChange?() }
    }

    private func dispatchTranscription(_ id: UUID) {
        guard !terminating, !stoppingProcessing, transcription != nil, transcriptionIdentities[id] == nil,
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
            let (service, role, _, _) = try currentTranscriptionService(checkDispatch: true)
            try reserveResultStorage(for: id, attemptID: attemptID, maximumEncodedResult: 4 * 256 * 1_024)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            try dispatchBackoff.require(service)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            let wave = try store.wavePreparation(id)
            try store.updateEntry(id) {
                $0.transcription = TranscriptionRecord(status: .waitingForSlot, attemptID: attemptID)
                $0.queueStage = .waitingForSlot
            }
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try PreparedTranscriptionRequest(audio: wave.read(), model: role.model)
            }
            observePreparation(worker, segmentID: id, attemptID: attemptID, generation: generation)
            unsavedStates[id] = nil
            started = true
        } catch {
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            handleUnsentTranscription(error, id: id)
        }
        onChange?()
    }

    private func observePreparation(_ worker: Task<PreparedTranscriptionRequest, Error>, segmentID id: UUID,
                                    attemptID: UUID, generation: UUID) {
        asrPreparations[id] = ASRPreparation(attemptID: attemptID, generation: generation, task: worker)
        Task { [weak self] in
            let result = await worker.result
            guard let self, self.isCurrentTranscription(id, attemptID: attemptID, generation: generation),
                  self.asrPreparations[id]?.attemptID == attemptID else { return }
            switch result {
            case .success(let prepared):
                self.asrPreparations[id]?.task = nil
                self.asrPreparations[id]?.ready = prepared
                // 准备占用的旧额度不能充当发送许可，尤其并发配置已降低时。
                self.releaseBudgetSlot(attemptID)
                self.pumpProcessing()
            case .failure:
                self.asrPreparations[id] = nil
                self.transcriptionIdentities[id] = nil
                self.setTranscriptionFailure(.storageFailure, id: id, status: .failed)
                self.releaseSlot(attemptID)
            }
            self.onChange?()
        }
    }

    private func cancelPreparation(_ id: UUID) {
        guard let preparation = asrPreparations.removeValue(forKey: id) else { return }
        if transcriptionIdentities[id] == preparation.attemptID { transcriptionIdentities[id] = nil }
        preparation.task?.cancel()
        releaseSlot(preparation.attemptID)
    }

    private func dispatchPreparedTranscription(_ id: UUID) {
        guard let preparation = asrPreparations[id], let prepared = preparation.ready, let transcription,
              isCurrentTranscription(id, attemptID: preparation.attemptID, generation: preparation.generation),
              let slot = mainRequestBudget.acquire(for: .transcription) else { return }
        let attemptID = preparation.attemptID, generation = preparation.generation
        requestSlots[attemptID] = slot
        var started = false
        defer { if !started { releaseSlot(attemptID) } }
        do {
            try reserveResultStorage(for: id, attemptID: attemptID, maximumEncodedResult: 4 * 256 * 1_024)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            let config = try processingSettings.load()
            mainRequestBudget.updateLimit(config.maximumConcurrentMainRequests)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation),
                  mainRequestBudget.activeCount <= mainRequestBudget.limit,
                  let entry = try? store.entry(id) else { return }
            let allowed = entry.queueStage != .waitingForResume && withinAutomaticSendingWindow(entry) && (canDispatch?(id) ?? true)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            guard allowed else {
                try store.updateEntry(id) { $0.queueStage = .waitingForResume }
                cancelPreparation(id)
                return
            }
            let (service, role, key, timeout) = try currentTranscriptionService(checkDispatch: true)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            try dispatchBackoff.require(service)
            let latestLimit = try processingSettings.load().maximumConcurrentMainRequests
            mainRequestBudget.updateLimit(latestLimit)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation),
                  mainRequestBudget.activeCount <= latestLimit else { return }
            guard role.model == prepared.model else {
                let worker = Task.detached(priority: .userInitiated) {
                    try PreparedTranscriptionRequest(audio: prepared.audio, model: role.model)
                }
                observePreparation(worker, segmentID: id, attemptID: attemptID, generation: generation)
                started = true
                return
            }
            guard let baseURL = URL(string: service.baseURL) else { throw TranscriptionFailure.invalidConfiguration }
            try store.updateEntry(id) {
                $0.transcription = TranscriptionRecord(status: .inFlight, attemptID: attemptID, serviceID: service.id, model: role.model)
                $0.queueStage = .transcribing
            }
            recoveryFault?(.transcriptionInFlight)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            let deadline = transcription.timing.instant + timeout
            let attempt = TranscriptionAttempt(id: attemptID, deadline: deadline,
                url: baseURL.appendingPathComponent("audio/transcriptions"), key: key, prepared: prepared,
                configuration: transcription.networkConfiguration) { [weak self] result, retryAfter in
                    Task { @MainActor in self?.receiveTranscription(result, segmentID: id, attemptID: attemptID, service: service, retryAfter: retryAfter) }
                }
            attempts[id] = attempt
            asrPreparations[id] = nil
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
            handleUnsentTranscription(error, id: id)
            if !autoEligible.contains(id) { cancelPreparation(id) }
        }
        onChange?()
    }

    private func handleUnsentTranscription(_ error: Error, id: UUID) {
        if let wait = error as? PendingDispatchWait {
            do {
                try store.updateEntry(id) {
                    $0.transcription = TranscriptionRecord(status: wait == .network ? .waitingForNetwork : .waitingForBackoff)
                    $0.queueStage = wait == .network ? .waitingForNetwork : .waitingForBackoff
                }
                unsavedStates[id] = nil
            } catch { setTranscriptionFailure(.storageFailure, id: id, status: .failed) }
            return
        }
        let failure = (error as? TranscriptionFailure) ?? .storageFailure
        let waiting: Set<TranscriptionFailure> = [.missingConfiguration, .invalidConfiguration, .missingCredentials, .credentialsUnavailable]
        setTranscriptionFailure(failure, id: id, status: waiting.contains(failure) ? .waitingForConfiguration : .failed)
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
                try self.reserveResultStorage(for: id, attemptID: attemptID, maximumEncodedResult: 4 * 256 * 1_024)
                guard self.isCurrentPolish(id, attemptID: attemptID, generation: generation) else { throw ProcessingInvalidated() }
                try self.store.updateEntry(id) {
                    $0.polish = PolishRecord(status: .inFlight, attemptID: attemptID, serviceID: attempt.serviceID, model: attempt.model)
                    $0.queueStage = .polishing
                }
                self.recoveryFault?(.polishInFlight)
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
                try store.updateEntry(id) {
                    $0.polish?.status = .cancelled; $0.polish?.failure = nil
                    if job.automaticDelivery { $0.delivery = .waiting; $0.queueStage = .waitingForPredecessor }
                    else { $0.queueStage = $0.disposition == .completed ? ($0.delivery == .skipped ? .skipped : .completed) : .awaitingManualDelivery }
                }
                if job.automaticDelivery { deliveryEligible.insert(id) }
                polishJobs[id] = nil
                drainDelivery()
            case .waiting(let failure):
                try store.updateEntry(id) {
                    $0.polish = PolishRecord(status: .waitingForConfiguration, attemptID: attemptID, failure: failure)
                    $0.queueStage = .waitingForPolishConfiguration
                }
                notice = failure.localizedDescription
            }
        } catch {
            guard isCurrentPolish(id, attemptID: attemptID, generation: generation) else { return }
            if let wait = error as? PendingDispatchWait {
                polishJobs[id]?.attempt = nil
                do {
                    try store.updateEntry(id) {
                        $0.polish = PolishRecord(status: wait == .network ? .waitingForNetwork : .waitingForBackoff, attemptID: attemptID)
                        $0.queueStage = wait == .network ? .waitingForNetwork : .waitingForBackoff
                    }
                    unsavedPolish[id] = nil
                } catch { failPolishPersistence(id, attemptID: attemptID, failure: .storageFailure) }
                onChange?()
                return
            }
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
        if let attempt = job.attempt { dispatchBackoff.record(completion.retryAfter, for: attempt.service) }
        do {
            let resultBytes: Int
            if case .success(let text) = completion.result { resultBytes = text.utf8.count }
            else { resultBytes = entry.rawTranscription?.utf8.count ?? 0 }
            try requireCapacity(for: UInt64(resultBytes * 4 + 65_536), excluding: attemptID)
            guard isCurrentPolish(id, attemptID: attemptID, generation: generation) else { return }
            try store.updateEntry(id, capacity: { bytes in
                try self.requireCapacity(for: bytes, excluding: attemptID)
                guard self.isCurrentPolish(id, attemptID: attemptID, generation: generation) else { throw ProcessingInvalidated() }
            }) {
                switch completion.result {
                case .success(let text):
                    $0.polishedText = text; $0.polish?.status = .succeeded; $0.polish?.failure = nil
                case .failure(let failure):
                    $0.polish?.status = failure == .timedOut ? .timedOut : .failed; $0.polish?.failure = failure
                }
                if job.automaticDelivery { $0.delivery = .waiting; $0.queueStage = .waitingForPredecessor }
                else { $0.queueStage = $0.disposition == .completed ? ($0.delivery == .skipped ? .skipped : .completed) : .awaitingManualDelivery }
            }
            recoveryFault?(.polishResultSaved)
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

    private func currentTranscriptionService(checkDispatch: Bool = false) throws -> (ModelService, ModelRoleConfiguration, String?, TimeInterval) {
        guard let transcription else { throw TranscriptionFailure.missingConfiguration }
        let config = try transcription.settings.load()
        guard let role = config.transcription,
              let service = config.services.first(where: { $0.id == role.serviceID }) else { throw TranscriptionFailure.missingConfiguration }
        if checkDispatch { try dispatchBackoff.require(service) }
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

    private func receiveTranscription(_ result: Result<String, TranscriptionFailure>, segmentID id: UUID, attemptID: UUID, service: ModelService? = nil, retryAfter: RetryAfter? = nil) {
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
        if let service { dispatchBackoff.record(retryAfter, for: service) }
        attempt.finish()
        switch result {
        case .failure(let failure):
            setTranscriptionFailure(failure, id: id, status: .failed)
        case .success(let text):
            let automaticDelivery = !recoveredIDs.contains(id)
            let polishID = polishClient == nil ? nil : UUID()
            let coachEnabled = (try? coachDependencies?.settings.load().enabled) ?? coachScheduler?.configuration.enabled ?? false
            let coachIdentity = coachEnabled && CoachInputLanguage.inferred(from: text) != .clearlyNonEnglish ? CoachWorkIdentity(segmentID: id) : nil
            do {
                try requireCapacity(for: UInt64(text.utf8.count * 4 + 65_536), excluding: attemptID)
                guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
                try store.updateEntry(id, capacity: { bytes in
                    try self.requireCapacity(for: bytes, excluding: attemptID)
                    guard self.isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { throw ProcessingInvalidated() }
                }) {
                    $0.transcription?.status = .succeeded; $0.transcription?.failure = nil
                    $0.rawTranscription = text; $0.delivery = automaticDelivery ? .waiting : .manual
                    $0.queueStage = polishClient == nil ? (automaticDelivery ? .waitingForPredecessor : .awaitingManualDelivery) : .waitingForPolishSlot
                    if let polishID { $0.polish = PolishRecord(status: .waitingForSlot, attemptID: polishID) }
                    if let coachIdentity { $0.coach = CoachWorkUpdate(identity: coachIdentity, status: .queued, dispatch: nil, result: nil, failure: nil) }
                }
                recoveryFault?(.rawCommittedBeforeMemory)
                autoEligible.remove(id)
                if let polishID { polishJobs[id] = PolishJob(attemptID: polishID, automaticDelivery: automaticDelivery) }
                else if automaticDelivery { deliveryEligible.insert(id) }
            } catch {
                guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
                setTranscriptionFailure(.storageFailure, id: id, status: .failed); return
            }
            storageReservations[attemptID] = nil
            enqueueCoach(id, raw: text)
            guard isCurrentTranscription(id, attemptID: attemptID, generation: generation) else { return }
            pumpProcessing()
            drainDelivery()
        }
    }

    private func enqueueCoach(_ id: UUID, raw: String) {
        guard !terminating, !stoppingProcessing, let scheduler = coachScheduler,
              let entry = try? store.entry(id), entry.disposition != .cancelled else { return }
        guard let queued = entry.coach, unsentCoach(entry) else { return }
        let identity = queued.identity
        coachIdentities[id] = identity
        do {
            if try !scheduler.enqueue(segmentID: id, rawText: raw, attemptID: identity.attemptID), coachIdentities[id] == identity {
                coachIdentities[id] = nil
                try store.updateEntry(id) {
                    $0.coach = CoachWorkUpdate(identity: identity, status: .cancelled, dispatch: queued.dispatch,
                        result: queued.result, failure: .cancelled)
                }
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
                recoveryFault?(.deliveryUncertain)
                deliveryEligible.remove(id)
                let result = targets[id].map { transcription.delivery.deliver(text, to: $0) } ?? .manual
                recoveryFault?(.deliveryPerformed)
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
        let (_, queueLimits) = try effectiveLimits()
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

    public var resourceConfiguration: ResourceConfiguration { get throws { try resourceSettings.load() } }

    public func invalidateStorageUsage() { store.invalidateUsage() }
    public func storageUsage() throws -> UInt64 { try store.bytesOnDisk() }
    public var reservedStorageBytes: UInt64 { get throws { try reservedBytes(excluding: nil) } }

    private func effectiveLimits() throws -> (RecordingLimits, QueueLimits) {
        guard usesConfiguredLimits else { return (limits, queueLimits) }
        let configuration = try resourceSettings.load()
        return try (configuration.recordingLimits, configuration.queueLimits)
    }

    private func reservedBytes(excluding attemptID: UUID?) throws -> UInt64 {
        try storageReservations.reduce(UInt64(0)) { total, item in
            guard item.key != attemptID else { return total }
            let (sum, overflow) = total.addingReportingOverflow(item.value)
            guard !overflow else { throw DictationError.storageUnavailable }
            return sum
        }
    }

    private func reserveResultStorage(for id: UUID, attemptID: UUID, maximumEncodedResult: UInt64) throws {
        let entryBytes = try store.entryStorageBytes(id)
        let reserve = 2 * (entryBytes + maximumEncodedResult + 65_536)
        try requireCapacity(for: reserve, excluding: attemptID)
        storageReservations[attemptID] = reserve
    }

    private func requireCapacity(for additionalBytes: UInt64, excluding attemptID: UUID? = nil) throws {
        // 留出的额度覆盖加密元数据及原子写入；真实磁盘余量另计。
        let finalizationReserve: UInt64 = 1_024 * 1_024
        let diskReserve: UInt64 = 64 * 1_024 * 1_024
        let (limits, _) = try effectiveLimits()
        let reserved = try reservedBytes(excluding: attemptID)
        let (needed, overflow) = additionalBytes.addingReportingOverflow(reserved)
        guard !overflow else { throw DictationError.storageUnavailable }
        let used = try store.bytesOnDisk()
        guard used <= limits.maximumLocalBytes,
              needed <= limits.maximumLocalBytes - used,
              finalizationReserve <= limits.maximumLocalBytes - used - needed else {
            throw DictationError.localStorageLimit
        }
        let available = try diskSpace(store.directory)
        guard available >= diskReserve + finalizationReserve + needed else { throw DictationError.diskSpaceLow }
    }
}
