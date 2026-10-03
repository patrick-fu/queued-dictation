import AppKit
import Foundation
import Testing
import DictationCore

@Suite(.serialized)
@MainActor
struct RecoveryBehaviorTests {
    @Test
    func aRecoveredUnsentCoachIsDurablyRetiredByTheSharedSwitchWithoutRepeatedDisabledWrites() async throws {
        let f = try ArtifactFixture(polishEnabled: false)
        defer { f.remove() }
        try f.coachSettings.save(.init(enabled: true))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        f.app.stopProcessing()
        let restarted = recoveryApp(f, delivery: f.delivery)
        defer { restarted.stopProcessing() }
        #expect(try restarted.recoveryItems().first?.canResumeUnsent == true)
        restarted.configurationChanged()
        let scheduler = try #require(restarted.coachScheduler)
        try scheduler.setEnabled(false)
        #expect(try restarted.history().first?.coach?.status == .cancelled)
        #expect(try restarted.recoveryItems().isEmpty)
        #expect(throws: DictationError.retryUnavailable) { try restarted.resumePendingProcessing(id) }
        let cancelledBytes = try savedFiles(f.history)
        for _ in 0..<3 { try scheduler.configurationChanged() }
        #expect(try savedFiles(f.history) == cancelledBytes)
        try scheduler.setEnabled(true)
        #expect(try restarted.history().first?.coach?.status == .cancelled)
        #expect(f.server.requests.count == 1 && scheduler.panelState.cards.isEmpty)
        f.clock.date.addTimeInterval(31 * 86_400)
        #expect(try restarted.history().isEmpty)
        #expect(try restarted.reservedStorageBytes == 0)
    }

    @Test
    func anOffPersistenceFailureKeepsItsSafeErrorAndDoesNotBlockIndependentMainWorkOrEraseAValidCoachResult() async throws {
        let f = try ArtifactFixture(polishEnabled: false)
        defer { f.remove() }
        let validID = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep this valid feedback."])
        f.server.replyChat(try await f.request(.coach), content: #"{"kind":"card","suggestions":[{"category":"expression","original":"Keep","improved":"Please keep","reason":"Add a polite request."}]}"#)
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .succeeded }
        let validCoach = try #require(f.app.history().first?.coach)
        try f.coachSettings.save(.init(enabled: true))
        let pausedID = try await f.record()
        f.server.reply(try await f.request(.asr, ordinal: 1), object: ["text": "Retire this unsent coach."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        var serviceConfiguration = try f.services.load(); serviceConfiguration.transcription = nil
        try f.services.save(serviceConfiguration)
        let mainID = try await f.record()
        f.app.stopProcessing()
        let restarted = recoveryApp(f, delivery: f.delivery)
        defer { restarted.stopProcessing() }
        let scheduler = try #require(restarted.coachScheduler)
        let folder = f.history.appendingPathComponent("history/\(pausedID)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let before = try savedFiles(f.history)
        try scheduler.setEnabled(false)
        #expect(try savedFiles(f.history) == before)
        #expect(restarted.coachFailure == .storageFailure && restarted.notice == CoachFailure.storageFailure.localizedDescription)
        #expect(try restarted.history().first { $0.id == pausedID }?.coach?.status == .waitingForResume)
        #expect(try restarted.recoveryItems().first { $0.id == pausedID }?.canResumeUnsent != true)
        #expect(throws: DictationError.retryUnavailable) { try restarted.resumePendingProcessing(pausedID) }
        #expect(try restarted.recoveryItems().first { $0.id == mainID }?.canResumeUnsent == true)
        try restarted.resumePendingProcessing(mainID)
        #expect(try restarted.history().first { $0.id == mainID }?.queueStage == .waitingForConfiguration)
        for _ in 0..<3 { try scheduler.configurationChanged() }
        #expect(try restarted.history().first { $0.id == validID }?.coach == validCoach)
        #expect(try restarted.history().first { $0.id == pausedID }?.coach?.status == .waitingForResume)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try scheduler.setEnabled(true)
        #expect(try restarted.history().first { $0.id == pausedID }?.coach?.status == .cancelled)
        #expect(try restarted.history().first { $0.id == validID }?.coach == validCoach)
        #expect(try restarted.recoveryItems().first { $0.id == pausedID }?.canResumeUnsent != true)
        #expect(f.server.requests.count == 3 && scheduler.panelState.cards.isEmpty)
        #expect(try restarted.reservedStorageBytes == 0)
    }

    @Test(arguments: ["coachFailed", "polishFailed", "polishUnknown"])
    func aCompletedMainOffersOnlyAnExplicitRetryForItsFailedOrUnknownFollowUpRole(_ roleCase: String) async throws {
        let coachRole = roleCase == "coachFailed", unknown = roleCase == "polishUnknown"
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: coachRole)
        defer { f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        let delivered = f.delivery.document.string
        if !coachRole {
            try f.polishSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "recovery-history-polish")))
            try f.app.repolish(id)
        }
        let role: ArtifactRole = coachRole ? .coach : .polish
        let oldRequest = try await f.request(role)
        if !unknown {
            f.server.reply(oldRequest, object: ["error": ["message": "synthetic controlled failure"]], status: 503)
            try await artifactWait {
                let entry = try? f.app.history().first
                return (coachRole ? entry?.coach?.status == .failed : entry?.polish?.status == .failed) &&
                    f.app.mainRequestBudget.activeCount == 0 && f.app.coachScheduler?.inFlightCount == 0
            }
        }
        f.app.stopProcessing()
        let restarted = recoveryApp(f, delivery: f.delivery)
        defer { restarted.stopProcessing() }
        restarted.configurationChanged()
        #expect(f.server.requests.count == 2 && f.delivery.document.string == delivered)
        let item = try restarted.recoveryItems().first { $0.id == id }
        #expect(coachRole ? item?.needsCoachRetry == true : item?.needsPolishRetry == true)
        if coachRole { try restarted.retryCoach(id) }
        else { try restarted.repolish(id) }
        let next = try await f.request(role, ordinal: 1)
        let busy = try restarted.recoveryItems().first { $0.id == id }
        #expect(coachRole ? busy?.needsCoachRetry != true : busy?.needsPolishRetry != true)
        f.server.replyChat(next, content: coachRole ? #"{"kind":"no_card"}"# : "I went yesterday.")
        try await artifactWait {
            let entry = try? restarted.history().first
            return coachRole ? entry?.coach?.status == .succeeded : entry?.polish?.status == .succeeded
        }
        #expect(f.server.requests.count == 3 && f.delivery.document.string == delivered)
        #expect(try restarted.history().first?.disposition == .completed)
        #expect(try restarted.reservedStorageBytes == 0)
        #expect(try restarted.recoveryItems().isEmpty)
    }

    @Test
    func anUnknownActualASRRequestNeedsANewExplicitAttemptAndNeverTargetsTheNewDocument() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        let id = try await f.record()
        let oldRequest = try await f.request(.asr)
        let oldAttempt = try #require(f.app.history().first?.transcription?.attemptID)
        f.app.stopProcessing()
        let delivery = ArtifactDocumentDelivery()
        delivery.document.string = "New window: "
        delivery.document.setSelectedRange(NSRange(location: delivery.document.string.utf16.count, length: 0))
        let restarted = recoveryApp(f, delivery: delivery)
        defer { restarted.stopProcessing() }
        restarted.configurationChanged()
        #expect(f.server.requests.count == 1)
        let item = try #require(restarted.recoveryItems().first)
        #expect(item.id == id && item.needsTranscriptionRetry && !item.canResumeUnsent)
        #expect(throws: DictationError.retryUnavailable) { try restarted.resumePendingProcessing(id) }
        try f.credentials.saveKey("recovery-new-fake-key", for: f.serviceID)
        var configuration = try f.services.load()
        configuration.transcription = .init(serviceID: f.serviceID, model: "recovery-new-asr")
        try f.services.save(configuration)
        try restarted.retryTranscription(id)
        let newRequest = try await f.request(.asr, ordinal: 1)
        #expect(newRequest.authorization == "Bearer recovery-new-fake-key")
        #expect(String(decoding: newRequest.body, as: UTF8.self).contains("recovery-new-asr"))
        #expect(try restarted.history().first?.transcription?.attemptID != oldAttempt)
        f.server.reply(newRequest, object: ["text": "Recovered once."])
        try await artifactWait { (try? restarted.history().first?.rawTranscription) == "Recovered once." }
        #expect(try restarted.history().first?.delivery == .manual)
        #expect(delivery.document.string == "New window: ")
        #expect(try restarted.queue().first?.isHead == true)
        try restarted.copyCurrentText(id)
        #expect(try restarted.queue().count == 1 && delivery.document.string == "New window: ")
        #expect(try restarted.insertCurrentTextAtCurrentCursor(id) == .delivered)
        #expect(delivery.document.string == "New window: Recovered once.")
        #expect(try restarted.queue().isEmpty && f.server.requests.count == 2)
        #expect(f.server.disconnected(oldRequest))
    }

    @Test
    func aDeliveredMainResultResumesOnlyItsDurableUnsentCoachWithTheLatestConfiguration() async throws {
        let f = try ArtifactFixture(polishEnabled: false)
        defer { f.remove() }
        try f.coachSettings.save(.init(enabled: true))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        #expect(try f.app.history().first?.coach?.status == .waitingForConfiguration)
        f.app.stopProcessing()
        let delivery = ArtifactDocumentDelivery()
        delivery.document.string = "Another window"
        let restarted = recoveryApp(f, delivery: delivery)
        defer { restarted.stopProcessing() }
        #expect(try restarted.history().first?.coach?.status == .waitingForResume)
        #expect(try restarted.recoveryItems().first?.canResumeUnsent == true)
        try f.credentials.saveKey("coach-recovery-fake-key", for: f.serviceID)
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "recovery-new-coach"), customPrompt: "恢复后的最新完整带教提示。"))
        restarted.configurationChanged()
        #expect(f.server.requests.count == 1)
        try restarted.resumePendingProcessing(id)
        let coach = try await f.request(.coach)
        #expect(coach.authorization == "Bearer coach-recovery-fake-key")
        #expect(coach.model == "recovery-new-coach" && coach.systemText?.contains("恢复后的最新完整带教提示。") == true)
        #expect(coach.userText == "I go yesterday.")
        f.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        try await artifactWait { (try? restarted.history().first?.coach?.status) == .succeeded }
        #expect(delivery.document.string == "Another window" && f.server.requests.count == 2)
        #expect(try restarted.history().first?.disposition == .completed)
        restarted.stopProcessing()
        let again = recoveryApp(f, delivery: ArtifactDocumentDelivery())
        defer { again.stopProcessing() }
        again.configurationChanged()
        #expect(try again.recoveryItems().isEmpty)
        #expect(again.coachScheduler?.panelState.cards.isEmpty == true && f.server.requests.count == 2)
    }

    @Test
    func aDurableHistoricalRepolishWaitsForExplicitResumeAndChangesOnlyHistory() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        let delivered = f.delivery.document.string
        try f.polishSettings.save(.init(enabled: true))
        try f.app.repolish(id)
        let originalAttempt = try #require(f.app.history().first?.polish?.attemptID)
        f.app.stopProcessing()
        let restarted = recoveryApp(f, delivery: f.delivery)
        defer { restarted.stopProcessing() }
        #expect(try restarted.history().first?.queueStage == .waitingForResume)
        try f.credentials.saveKey("polish-recovery-fake-key", for: f.serviceID)
        try f.polishSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "recovery-new-polish"), customPrompt: "最新完整润色提示。"))
        restarted.configurationChanged()
        #expect(f.server.requests.count == 1)
        try restarted.resumePendingProcessing(id)
        let polish = try await f.request(.polish)
        #expect(polish.authorization == "Bearer polish-recovery-fake-key" && polish.model == "recovery-new-polish")
        #expect(polish.systemText?.contains("最新完整润色提示。") == true && polish.userText == "I go yesterday.")
        #expect(try restarted.history().first?.polish?.attemptID == originalAttempt)
        f.server.replyChat(polish, content: "I went yesterday.")
        try await artifactWait { (try? restarted.history().first?.polishedText) == "I went yesterday." }
        #expect(f.delivery.document.string == delivered && f.server.requests.count == 2)
        #expect(try restarted.history().first?.disposition == .completed)
    }

    @Test
    func anUnknownCoachCanBeRetriedOnceWhileLiveWorkAndValidResultsAreNotRetryable() async throws {
        let f = try ArtifactFixture(polishEnabled: false)
        defer { f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        let oldRequest = try await f.request(.coach)
        try await artifactWait { (try? f.app.history().first?.disposition) == .completed }
        let oldIdentity = try #require(f.app.history().first?.coach?.identity)
        f.app.stopProcessing()
        let delivery = ArtifactDocumentDelivery()
        delivery.document.string = "Keep this new document."
        let restarted = recoveryApp(f, delivery: delivery)
        defer { restarted.stopProcessing() }
        #expect(try restarted.recoveryItems().first?.needsCoachRetry == true)
        restarted.configurationChanged()
        #expect(f.server.requests.count == 2)
        let scheduler = try #require(restarted.coachScheduler)
        let unknownCoach = try #require(restarted.history().first?.coach)
        try scheduler.setEnabled(false)
        #expect(try restarted.history().first?.coach == unknownCoach)
        #expect(try restarted.recoveryItems().first?.needsCoachRetry != true)
        try scheduler.setEnabled(true)
        #expect(try restarted.history().first?.coach == unknownCoach)
        try f.credentials.saveKey("new-coach-retry-fake-key", for: f.serviceID)
        try restarted.retryCoach(id)
        let request = try await f.request(.coach, ordinal: 1)
        #expect(request.authorization == "Bearer new-coach-retry-fake-key")
        #expect(try restarted.history().first?.coach?.identity != oldIdentity)
        #expect(try restarted.recoveryItems().first?.needsCoachRetry != true)
        #expect(throws: DictationError.retryUnavailable) { try restarted.retryCoach(id) }
        f.server.replyChat(request, content: "{\"kind\":\"no_card\"}")
        try await artifactWait { (try? restarted.history().first?.coach?.status) == .succeeded }
        #expect(throws: DictationError.retryUnavailable) { try restarted.retryCoach(id) }
        #expect(f.server.requests.count == 3 && delivery.document.string == "Keep this new document.")
        #expect(f.server.disconnected(oldRequest))
    }
}

@MainActor
private func recoveryApp(_ f: ArtifactFixture, delivery: any TextDelivering) -> RecordingApplication {
    RecordingApplication(source: ArtifactMicrophone(), historyDirectory: f.history, keys: TestDataKey(), now: { f.clock.date },
        diskSpace: { _ in f.capacity.bytes },
        transcription: TranscriptionDependencies(settings: f.services, credentials: f.credentials, delivery: delivery, timing: f.timing),
        polish: PolishClient(settings: f.polishSettings, services: f.services, credentials: f.credentials, timing: f.timing),
        coach: CoachDependencies(settings: f.coachSettings, services: f.services, credentials: f.credentials, timing: f.timing),
        resourceSettings: f.resources, network: f.network, historyRetentionSettings: f.retention)
}
