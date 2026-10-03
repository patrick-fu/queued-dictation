import Foundation

public enum CoachInputLanguage: Sendable {
    case clearlyNonEnglish, englishOrUncertain
    public static func inferred(from text: String) -> CoachInputLanguage {
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains)
        // 只对纯汉字表达作明确排除，其他脚本、缩写及中英混说交给同一次带教请求。
        return !letters.isEmpty && letters.allSatisfy(isHan) ? .clearlyNonEnglish : .englishOrUncertain
    }
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
    }
}
public enum CoachWorkStatus: String, Codable, Sendable {
    case queued, waitingForConfiguration, waitingForNetwork, waitingForBackoff, waitingForResume, inFlight, succeeded, failed, timedOut, cancelled, interrupted
}

public struct CoachWorkUpdate: Codable, Equatable, Sendable {
    public let identity: CoachWorkIdentity
    public let status: CoachWorkStatus
    public let dispatch: CoachDispatch?
    public let result: CoachResult?
    public let failure: CoachFailure?
}

@MainActor
public final class CoachWorkScheduler {
    public private(set) var panelState: CoachPanelState
    public private(set) var configuration: CoachConfiguration
    public private(set) var latestFailure: CoachFailure?
    public var onChange: (() -> Void)?
    public var pendingCount: Int { pending.count }
    public var inFlightCount: Int { active.count + preparingCount }
    func containsWork(for segmentID: UUID) -> Bool {
        pending.contains { $0.identity.segmentID == segmentID } || active[segmentID] != nil || preparations[segmentID] != nil
    }
    private let settings: CoachSettings
    private let client: CoachClient
    private let timing: any RequestTiming
    var waveForSegment: ((UUID) throws -> EncryptedWavePreparation)?
    private let onUpdate: (CoachWorkUpdate) throws -> Void
    private let canDispatch: (CoachWorkIdentity) -> Bool
    var dispatchGate: ((ModelService) throws -> Void)? {
        get { client.dispatchGate }
        set { client.dispatchGate = newValue }
    }
    var onRetryAfter: ((ModelService, RetryAfter?) -> Void)?
    private let audioForSegment: (UUID) throws -> Data?
    private struct Job {
        let identity: CoachWorkIdentity
        let rawText: String
        var status: CoachWorkStatus = .queued
        var failure: CoachFailure?
        var readyForDispatch = false
    }
    private struct Active {
        let job: Job
        let request: CoachRequest
    }
    private var pending: [Job] = []
    private var active: [UUID: Active] = [:]
    private struct Preparation {
        let identity: CoachWorkIdentity
        let workerID: UUID
        let beganAt: TimeInterval
        let elapsed: TimeInterval
        var worker: Task<PreparedCoachRequest, Error>?
        var ready: PreparedCoachRequest?
        var deadlineTask: Task<Void, Never>?
    }
    private var preparations: [UUID: Preparation] = [:]
    private var preparingCount: Int { preparations.values.filter { $0.worker != nil }.count }
    private var pumping = false
    private var generation = UUID()
    private var stopping = false

    public init(settings: CoachSettings, services: ServiceSettings, credentials: any ServiceCredentialStoring,
                networkConfiguration: URLSessionConfiguration = .ephemeral, timing: any RequestTiming = ContinuousRequestTiming(),
                canDispatch: @escaping (CoachWorkIdentity) -> Bool = { _ in true },
                audioForSegment: @escaping (UUID) throws -> Data? = { _ in nil },
                onUpdate: @escaping (CoachWorkUpdate) throws -> Void) throws {
        self.settings = settings; self.onUpdate = onUpdate; self.canDispatch = canDispatch; self.timing = timing
        self.audioForSegment = audioForSegment
        configuration = try settings.load()
        panelState = CoachPanelState(enabled: configuration.enabled)
        client = CoachClient(settings: settings, services: services, credentials: credentials,
                             networkConfiguration: networkConfiguration, timing: timing)
    }

    @discardableResult
    public func enqueue(segmentID: UUID, rawText: String, language: CoachInputLanguage? = nil,
                        cancelled: Bool = false, attemptID: UUID = UUID()) throws -> Bool {
        let generation = self.generation
        try configurationChanged()
        guard generation == self.generation, configuration.enabled, !cancelled, (language ?? .inferred(from: rawText)) != .clearlyNonEnglish,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              active[segmentID] == nil, !pending.contains(where: { $0.identity.segmentID == segmentID }) else { return false }
        let job = Job(identity: CoachWorkIdentity(segmentID: segmentID, attemptID: attemptID), rawText: rawText)
        pending.append(job)
        do { try emit(job.identity, status: .queued) }
        catch {
            pending.removeAll { $0.identity == job.identity }
            throw error
        }
        guard isPending(job.identity, generation: generation),
              let index = pending.firstIndex(where: { $0.identity == job.identity }) else { return false }
        pending[index].readyForDispatch = true
        pump()
        onChange?()
        return generation == self.generation
    }

    public func setEnabled(_ enabled: Bool) throws {
        var configuration = try settings.load()
        configuration.enabled = enabled
        try settings.save(configuration)
        try configurationChanged()
    }

    public func configurationChanged() throws {
        let generation = self.generation
        configuration = try settings.load()
        panelState.setEnabled(configuration.enabled)
        if !configuration.enabled {
            for id in Array(preparations.keys) { cancelPreparation(id) }
            for index in pending.indices { pending[index].status = .cancelled; pending[index].readyForDispatch = false }
            let requests = active.values.map(\.request)
            requests.forEach { $0.cancelForDisabled() }
            while generation == self.generation, let job = pending.first(where: { $0.status == .cancelled }) {
                pending.removeAll { $0.identity == job.identity }
                record(job.identity, status: .cancelled, failure: .cancelled)
            }
        } else { pump() }
        guard generation == self.generation else { return }
        onChange?()
    }

    public func removeCard(_ segmentID: UUID) {
        panelState.removeCard(segmentID)
        onChange?()
    }

    public func cancel(_ segmentID: UUID) {
        cancelPreparation(segmentID)
        let identities = pending.filter { $0.identity.segmentID == segmentID }.map(\.identity)
        pending.removeAll { $0.identity.segmentID == segmentID }
        if let item = active.removeValue(forKey: segmentID) {
            panelState.invalidate(item.job.identity)
            item.request.cancel()
            record(item.job.identity, status: .cancelled, failure: .cancelled)
        }
        for identity in identities { record(identity, status: .cancelled, failure: .cancelled) }
        pump(); onChange?()
    }

    public func removeSegment(_ segmentID: UUID) {
        cancelPreparation(segmentID)
        pending.removeAll { $0.identity.segmentID == segmentID }
        panelState.removeSegment(segmentID)
        let item = active.removeValue(forKey: segmentID)
        item?.request.cancel()
        // 删除后的回调不能写回已删除的历史；取消通知也必须在此边界停止。
        pump(); onChange?()
    }

    public func stopProcessing() {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        generation = UUID()
        for id in Array(preparations.keys) { cancelPreparation(id) }
        let requests = active.values.map(\.request)
        active.removeAll(); pending.removeAll()
        panelState = CoachPanelState(enabled: configuration.enabled)
        requests.forEach { $0.cancel() }
        onChange?()
    }

    private func pump() {
        guard !pumping, !stopping else { return }
        do { configuration = try settings.load() }
        catch { latestFailure = .invalidConfiguration; return }
        guard configuration.enabled else { return }
        let generation = self.generation
        pumping = true
        defer { pumping = false }
        for job in pending where job.readyForDispatch {
            let allowed = canDispatch(job.identity)
            guard isPending(job.identity, generation: generation) else { continue }
            if !allowed { cancelPreparation(job.identity.segmentID); wait(job, status: .waitingForResume, generation: generation) }
        }
        var visited: Set<CoachWorkIdentity> = []
        while generation == self.generation, configuration.enabled, active.count + preparingCount < configuration.concurrency,
              let job = pending.first(where: { $0.readyForDispatch && !visited.contains($0.identity) }) {
            visited.insert(job.identity)
            let allowed = canDispatch(job.identity)
            guard isPending(job.identity, generation: generation) else { continue }
            guard allowed else { wait(job, status: .waitingForResume, generation: generation); continue }
            if preparations[job.identity.segmentID]?.worker != nil { continue }
            do {
                let willStart: (CoachDispatch) throws -> Void = { dispatch in
                        guard self.isPending(job.identity, generation: generation) else { throw DispatchInvalidated() }
                        if self.preparations[job.identity.segmentID] != nil {
                            try self.checkPreparedPermission(job, generation: generation)
                        }
                        try self.emit(job.identity, status: .inFlight, dispatch: dispatch)
                        // 持久化回调可同步删除、关闭或停止；返回后再次确认，才能发送本段。
                        guard self.isPending(job.identity, generation: generation) else { throw DispatchInvalidated() }
                        if let index = self.pending.firstIndex(where: { $0.identity == job.identity }) { self.pending[index].status = .inFlight }
                        if self.preparations[job.identity.segmentID] != nil {
                            try self.checkPreparedPermission(job, generation: generation)
                        }
                        self.panelState.begin(job.identity, rawText: job.rawText, inputMode: dispatch.inputMode)
                    }
                let request: CoachRequest
                if let preparation = preparations[job.identity.segmentID], let payload = preparation.ready {
                    let selection = try client.currentSelection()
                    if payload.model != selection.role.model || payload.prompt != selection.configuration.prompt || payload.inputMode != selection.configuration.inputMode {
                        try beginPreparation(job, selection: selection, existing: payload, elapsed: preparation.elapsed, generation: generation)
                        continue
                    }
                    do {
                        request = try client.startPrepared(segmentID: job.identity.segmentID, attemptID: job.identity.attemptID,
                            rawText: job.rawText, payload: payload, preparationElapsed: preparation.elapsed, willStart: willStart,
                            completion: { [weak self] result in self?.receive(result, identity: job.identity) })
                    } catch let changed as CoachClient.PreparationChanged {
                        wait(job, status: .queued, generation: generation)
                        guard isPending(job.identity, generation: generation) else { continue }
                        let selection = try client.currentSelection()
                        try beginPreparation(job, selection: selection, existing: payload,
                            elapsed: max(0, timing.instant - changed.startedAt), generation: generation)
                        continue
                    }
                } else if waveForSegment != nil, configuration.inputMode == .originalAudio {
                    guard preparations.count < configuration.concurrency else { continue }
                    try beginPreparation(job, selection: client.currentSelection(), existing: nil, elapsed: 0, generation: generation)
                    continue
                } else {
                    request = try client.start(segmentID: job.identity.segmentID, attemptID: job.identity.attemptID,
                        rawText: job.rawText, audioForSegment: audioForSegment, willStart: willStart,
                        completion: { [weak self] result in self?.receive(result, identity: job.identity) })
                }
                guard isPending(job.identity, generation: generation) else { request.cancel(); continue }
                cancelPreparation(job.identity.segmentID)
                pending.removeAll { $0.identity == job.identity }
                active[job.identity.segmentID] = Active(job: job, request: request)
            } catch {
                guard isPending(job.identity, generation: generation) else { continue }
                if error is PreparedSlotWait {
                    wait(job, status: .queued, generation: generation)
                    continue
                }
                if error is PreparedWindowWait {
                    cancelPreparation(job.identity.segmentID)
                    wait(job, status: .waitingForResume, generation: generation)
                    continue
                }
                if let wait = error as? PendingDispatchWait {
                    self.wait(job, status: wait == .network ? .waitingForNetwork : .waitingForBackoff, generation: generation)
                    continue
                }
                let failure = (error as? CoachFailure) ?? .storageFailure
                let waits: Set<CoachFailure> = [.missingConfiguration, .invalidConfiguration, .missingCredentials, .credentialsUnavailable]
                if waits.contains(failure) { wait(job, status: .waitingForConfiguration, failure: failure, generation: generation) }
                else {
                    cancelPreparation(job.identity.segmentID)
                    pending.removeAll { $0.identity == job.identity }
                    panelState.invalidate(job.identity)
                    record(job.identity, status: failure == .disabled ? .cancelled : failure == .timedOut ? .timedOut : .failed, failure: failure)
                }
            }
        }
    }

    private struct PreparedSlotWait: Error {}

    private func checkPreparedPermission(_ job: Job, generation: UUID) throws {
        configuration = try settings.load()
        guard isPending(job.identity, generation: generation) else { throw DispatchInvalidated() }
        guard active.count + preparingCount < configuration.concurrency else { throw PreparedSlotWait() }
        let allowed = canDispatch(job.identity)
        guard isPending(job.identity, generation: generation) else { throw DispatchInvalidated() }
        guard allowed else { throw PreparedWindowWait() }
    }

    private struct PreparedWindowWait: Error {}

    private func beginPreparation(_ job: Job, selection: CoachClient.Selection, existing: PreparedCoachRequest?,
                                  elapsed: TimeInterval, generation: UUID) throws {
        guard CoachSettings.validText(job.rawText, maximumBytes: 256 * 1_024) else { throw CoachFailure.inputTooLarge }
        guard isPending(job.identity, generation: generation) else { throw DispatchInvalidated() }
        let wave = selection.configuration.inputMode == .originalAudio && existing?.audio == nil
            ? try waveForSegment?(job.identity.segmentID) : nil
        guard isPending(job.identity, generation: generation) else { throw DispatchInvalidated() }
        let beganAt = timing.instant
        guard elapsed < selection.configuration.timeout else { throw CoachFailure.timedOut }
        let worker = Task.detached(priority: .userInitiated) {
            let audio = try existing?.audio?.wave ?? wave?.read()
            return try PreparedCoachRequest(rawText: job.rawText, model: selection.role.model, prompt: selection.configuration.prompt,
                inputMode: selection.configuration.inputMode, wave: audio)
        }
        let workerID = UUID()
        preparations[job.identity.segmentID] = Preparation(identity: job.identity, workerID: workerID, beganAt: beganAt, elapsed: elapsed, worker: worker)
        monitorPreparation(job.identity, workerID: workerID, generation: generation)
        Task { [weak self] in
            let result = await worker.result
            guard let self, self.isPending(job.identity, generation: generation),
                  let preparation = self.preparations[job.identity.segmentID], preparation.identity == job.identity,
                  preparation.workerID == workerID else { return }
            preparation.deadlineTask?.cancel()
            switch result {
            case .success(let payload):
                self.preparations[job.identity.segmentID] = Preparation(identity: job.identity, workerID: workerID, beganAt: preparation.beganAt,
                    elapsed: preparation.elapsed + max(0, self.timing.instant - preparation.beganAt), ready: payload)
            case .failure(let error):
                self.cancelPreparation(job.identity.segmentID)
                self.pending.removeAll { $0.identity == job.identity }
                let failure = (error as? CoachFailure) ?? .audioUnavailable
                self.record(job.identity, status: failure == .timedOut ? .timedOut : .failed, failure: failure)
            }
            self.pump(); self.onChange?()
        }
    }

    private func monitorPreparation(_ identity: CoachWorkIdentity, workerID: UUID, generation: UUID) {
        preparations[identity.segmentID]?.deadlineTask = Task { [weak self] in
            guard let self else { return }
            while self.isPending(identity, generation: generation),
                  let item = self.preparations[identity.segmentID], item.identity == identity, item.workerID == workerID, item.worker != nil {
                let timeout = (try? self.settings.load().timeout) ?? self.configuration.timeout
                let deadline = item.beganAt + timeout - item.elapsed
                do { try await self.timing.wait(until: deadline) } catch { return }
                guard !Task.isCancelled, self.isPending(identity, generation: generation),
                      let current = self.preparations[identity.segmentID], current.identity == identity,
                      current.workerID == workerID, current.worker != nil else { return }
                let latestTimeout = (try? self.settings.load().timeout) ?? self.configuration.timeout
                guard self.timing.instant >= current.beganAt + latestTimeout - current.elapsed else { continue }
                self.cancelPreparation(identity.segmentID)
                self.pending.removeAll { $0.identity == identity }
                self.record(identity, status: .timedOut, failure: .timedOut)
                self.pump(); self.onChange?()
                return
            }
        }
    }

    private func cancelPreparation(_ id: UUID) {
        let preparation = preparations.removeValue(forKey: id)
        preparation?.worker?.cancel()
        preparation?.deadlineTask?.cancel()
    }

    private func receive(_ result: Result<CoachResult, CoachFailure>, identity: CoachWorkIdentity) {
        guard let item = active[identity.segmentID], item.job.identity == identity else { return }
        let generation = self.generation, dispatch = item.request.dispatch
        onRetryAfter?(item.request.service, item.request.retryAfter)
        guard generation == self.generation, active[identity.segmentID]?.job.identity == identity else { return }
        switch result {
        case .success(let feedback):
            do {
                try emit(identity, status: .succeeded, dispatch: dispatch, result: feedback)
                guard generation == self.generation, active[identity.segmentID]?.job.identity == identity else { return }
                panelState.complete(identity, result: feedback)
            } catch {
                guard generation == self.generation, active[identity.segmentID]?.job.identity == identity else { return }
                panelState.invalidate(identity)
                record(identity, status: .failed, dispatch: dispatch, failure: .storageFailure)
            }
        case .failure(let failure):
            panelState.invalidate(identity)
            let status: CoachWorkStatus = failure == .timedOut ? .timedOut : failure == .cancelled ? .cancelled : .failed
            record(identity, status: status, dispatch: dispatch, failure: failure)
        }
        guard generation == self.generation, active[identity.segmentID]?.job.identity == identity else { return }
        active[identity.segmentID] = nil
        pump(); onChange?()
    }

    private func wait(_ job: Job, status: CoachWorkStatus, failure: CoachFailure? = nil, generation: UUID) {
        guard let index = pending.firstIndex(where: { $0.identity == job.identity }) else { return }
        latestFailure = failure ?? latestFailure
        guard pending[index].status != status || pending[index].failure != failure else { return }
        do {
            try emit(job.identity, status: status, failure: failure)
            guard isPending(job.identity, generation: generation),
                  let index = pending.firstIndex(where: { $0.identity == job.identity }) else { return }
            pending[index].status = status
            pending[index].failure = failure
        } catch {
            guard generation == self.generation, pending.contains(where: { $0.identity == job.identity }) else { return }
            if preparations[job.identity.segmentID]?.identity == job.identity { cancelPreparation(job.identity.segmentID) }
            pending.removeAll { $0.identity == job.identity }
            latestFailure = .storageFailure
        }
    }

    private func isPending(_ identity: CoachWorkIdentity, generation: UUID) -> Bool {
        generation == self.generation && configuration.enabled
            && pending.contains { $0.identity == identity && $0.status != .cancelled }
    }

    private struct DispatchInvalidated: Error {}

    private func record(_ identity: CoachWorkIdentity, status: CoachWorkStatus, dispatch: CoachDispatch? = nil,
                        failure: CoachFailure? = nil) {
        do { try emit(identity, status: status, dispatch: dispatch, failure: failure) }
        catch { latestFailure = .storageFailure }
    }

    private func emit(_ identity: CoachWorkIdentity, status: CoachWorkStatus, dispatch: CoachDispatch? = nil,
                      result: CoachResult? = nil, failure: CoachFailure? = nil) throws {
        latestFailure = failure ?? latestFailure
        try onUpdate(CoachWorkUpdate(identity: identity, status: status, dispatch: dispatch, result: result, failure: failure))
    }
}
