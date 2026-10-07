import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DictationCore

@Suite(.serialized)
@MainActor
struct ModelPipelineBehaviorTests {
    @Test
    func generatedAudioProducesEncryptedRawPolishAndIndependentCoachBeforeOrderedDelivery() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        let asr = try await fixture.request(.asr)
        let waveStart = try #require(asr.body.range(of: Data("RIFF".utf8))?.lowerBound)
        #expect(asr.body.subdata(in: waveStart + 8..<waveStart + 16) == Data("WAVEfmt ".utf8))
        #expect(asr.body.subdata(in: waveStart + 44..<waveStart + 8_044) == testAudio().samples)
        #expect(asr.authorization == "Bearer pipeline-fake-key")
        fixture.server.reply(asr, object: ["text": "I go to office yesterday."])
        let polish = try await fixture.request(.polish)
        let coach = try await fixture.request(.coach)
        let waiting = try #require(fixture.app.history().first)
        #expect(waiting.id == id)
        #expect(waiting.rawTranscription == "I go to office yesterday.")
        #expect(waiting.polishedText == nil)
        #expect(waiting.polish?.status == .inFlight)
        #expect(waiting.coach?.status == .inFlight)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(polish.jsonKeys == ["model", "messages"])
        #expect(polish.userText == "I go to office yesterday.")
        #expect(polish.systemText == "完整润色提示词，仅整理本段。")
        #expect(coach.jsonKeys == ["model", "stream", "messages"])
        #expect(coach.userText == "I go to office yesterday.")
        #expect(coach.systemText == "完整文本带教提示词，不评流利度。")
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { fixture.app.coachScheduler?.panelState.cards.count == 1 }
        #expect(try fixture.app.history().first?.coach?.status == .succeeded)
        #expect(fixture.delivery.document.string.isEmpty)
        fixture.server.replyChat(polish, content: "I went to the office yesterday.")
        try await pipelineWait { fixture.delivery.document.string == "I went to the office yesterday." }
        let entry = try #require(fixture.app.history().first)
        #expect(entry.polishedText == "I went to the office yesterday.")
        #expect(entry.polish?.status == .succeeded)
        #expect(entry.disposition == .completed)
        #expect(entry.recordingEndedAt != nil)
        let ciphertext = try savedFiles(fixture.history)
        for bytes in ciphertext.values {
            #expect(bytes.starts(with: Data("QDENC1".utf8)))
            #expect(bytes.range(of: Data("I go to office yesterday.".utf8)) == nil)
            #expect(bytes.range(of: Data("I went to the office yesterday.".utf8)) == nil)
            #expect(bytes.range(of: Data("pipeline-fake-key".utf8)) == nil)
        }
        let reopened = RecordingApplication(source: PipelineMicrophone(), historyDirectory: fixture.history, keys: TestDataKey())
        #expect(try reopened.history().first == entry)
        fixture.app.coachScheduler?.removeCard(id)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
        #expect(try fixture.app.history().first?.coach?.result != nil)
    }

    @Test
    func missingPolishConfigurationWaitsWhileCoachContinuesAndDispatchUsesTheLatestSharedService() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        try fixture.polishSettings.save(PolishConfiguration(enabled: true))
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        let coach = try await fixture.request(.coach)
        try await pipelineWait { (try? fixture.app.history().first?.polish?.status) == .waitingForConfiguration }
        #expect(try fixture.app.queue().first?.stage == .waitingForPolishConfiguration)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.server.requests.filter { $0.role == .polish }.isEmpty)
        fixture.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        try await pipelineWait { (try? fixture.app.history().first?.coach?.status) == .succeeded }
        try fixture.services.saveService(ModelService(id: fixture.serviceID, name: "最新共享配置", baseURL: fixture.server.baseURL + "/changed", authentication: .bearerToken),
            newKey: "latest-fake-polish-key", credentials: fixture.credentials)
        try fixture.polishSettings.save(PolishConfiguration(enabled: true,
            role: .init(serviceID: fixture.serviceID, model: "pipeline-polish-latest"), customPrompt: "实际派发时的最新完整提示词。"))
        fixture.app.configurationChanged()
        let request = try await fixture.request(.polish)
        #expect(request.path == "/changed/chat/completions")
        #expect(request.authorization == "Bearer latest-fake-polish-key")
        #expect(request.model == "pipeline-polish-latest")
        #expect(request.systemText == "实际派发时的最新完整提示词。")
        #expect(request.userText == "I go yesterday.")
        fixture.server.replyChat(request, content: "I went yesterday.")
        try await pipelineWait { fixture.delivery.document.string == "I went yesterday." }
        #expect(try fixture.app.currentText(id) == "I went yesterday.")
        #expect(try fixture.app.rawTranscription(id) == "I go yesterday.")
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 1)
    }

    @Test
    func threeSharedRequestsAndThreeIndependentCoachRequestsKeepMainFIFOAndCardArrivalOrder() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        var ids: [UUID] = []
        var asr: [PipelineLoopbackServer.Request] = []
        for index in 0..<5 {
            ids.append(try await fixture.record())
            if index < 3 { asr.append(try await fixture.request(.asr, ordinal: index)) }
        }
        #expect(fixture.app.mainRequestBudget.activeCount == 3)
        var polishes: [String: PipelineLoopbackServer.Request] = [:]
        var coaches: [String: PipelineLoopbackServer.Request] = [:]
        for index in [2, 1, 0] {
            let raw = "I go \(["A", "B", "C"][index])."
            fixture.server.reply(asr[index], object: ["text": raw])
            polishes[raw] = try await fixture.request(.polish, raw: raw)
            coaches[raw] = try await fixture.request(.coach, raw: raw)
            #expect(fixture.app.mainRequestBudget.activeCount == 3)
        }
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 3)
        #expect(fixture.app.coachScheduler?.inFlightCount == 3)
        for index in [2, 1, 0] {
            let raw = "I go \(["A", "B", "C"][index])."
            fixture.server.replyChat(try #require(coaches[raw]), content: pipelineCard(original: "I go", improved: "I went"))
            try await pipelineWait { fixture.app.coachScheduler?.panelState.cards.count == 3 - index }
        }
        #expect(fixture.app.coachScheduler?.panelState.cards.map(\.id) == [ids[2], ids[1], ids[0]])
        #expect(fixture.delivery.document.string.isEmpty)
        fixture.server.replyChat(try #require(polishes["I go C."]), content: "C.")
        _ = try await fixture.request(.asr, ordinal: 3)
        #expect(fixture.delivery.document.string.isEmpty)
        fixture.server.replyChat(try #require(polishes["I go B."]), content: "B.")
        _ = try await fixture.request(.asr, ordinal: 4)
        #expect(fixture.delivery.document.string.isEmpty)
        fixture.server.replyChat(try #require(polishes["I go A."]), content: "A.")
        try await pipelineWait { fixture.delivery.document.string == "A.B.C." }
        #expect(try fixture.app.queue().map(\.id) == [ids[3], ids[4]])
        #expect(fixture.delivery.copied == "等待时用户新复制的内容")
    }

    @Test(arguments: [
        PipelinePolishFailure(status: 429, body: "{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"fake-provider-secret\"}}", failure: .quota),
        PipelinePolishFailure(status: 200, body: "{\"choices\":[{\"message\":{\"content\":\" \"}}]}", failure: .emptyResult),
        PipelinePolishFailure(status: 200, body: "{\"wrong_format\":true}", failure: .incompatible)
    ])
    func sentPolishFailuresDeliverRawOnceAndLeaveIndependentCoachRunning(_ sample: PipelinePolishFailure) async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        fixture.server.reply(polish, body: Data(sample.body.utf8), status: sample.status)
        try await pipelineWait { fixture.delivery.document.string == "I go yesterday." }
        #expect(try fixture.app.history().first?.polish?.failure == sample.failure)
        #expect(try fixture.app.history().first?.polishedText == nil)
        #expect(try fixture.app.currentText(id) == "I go yesterday.")
        #expect(fixture.app.coachScheduler?.inFlightCount == 1)
        fixture.app.configurationChanged()
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { fixture.app.coachScheduler?.panelState.cards.count == 1 }
        #expect(fixture.server.requests.filter { $0.role == .polish }.count == 1)
        #expect(fixture.delivery.document.string == "I go yesterday.")
        #expect(fixture.app.notice?.contains("fake-provider-secret") != true)
    }

    @Test
    func polishFullDeadlineCancelsTransportFallsBackToRawAndDoesNotCancelCoach() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        var configuration = try fixture.coachSettings.load()
        configuration.timeout = 60
        try fixture.coachSettings.save(configuration)
        fixture.app.configurationChanged()
        _ = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        fixture.timing.advance(to: 30)
        try await pipelineWait { fixture.delivery.document.string == "I go yesterday." && fixture.server.disconnected(polish) }
        #expect(try fixture.app.history().first?.polish?.status == .timedOut)
        #expect(fixture.app.coachScheduler?.inFlightCount == 1)
        fixture.server.replyChat(polish, content: "迟到结果不能覆盖。")
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { fixture.app.coachScheduler?.panelState.cards.count == 1 }
        #expect(try fixture.app.history().first?.polishedText == nil)
        #expect(fixture.delivery.document.string == "I go yesterday.")
    }

    @Test
    func manualRepolishSharesTheMainSlotUsesRawAndOnlyUpdatesHistoryAfterOriginalDelivery() async throws {
        let fixture = try PipelineFixture(coachEnabled: false, concurrency: 1)
        defer { fixture.remove() }
        let first = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        fixture.server.replyChat(try await fixture.request(.polish), content: "Original delivery.")
        try await pipelineWait { fixture.delivery.document.string == "Original delivery." }
        let oldAttempt = try #require(fixture.app.history().first?.polish?.attemptID)
        let second = try await fixture.record()
        let secondASR = try await fixture.request(.asr, ordinal: 1)
        try fixture.app.repolish(first)
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        #expect(fixture.server.requests.filter { $0.role == .polish }.count == 1)
        var configuration = try fixture.polishSettings.load()
        configuration.role?.model = "pipeline-polish-manual-latest"
        configuration.customPrompt = "排队之后修改的提示词。"
        try fixture.polishSettings.save(configuration)
        fixture.server.reply(secondASR, object: ["text": "I go second."])
        let manual = try await fixture.request(.polish, raw: "I go yesterday.", ordinal: 1)
        #expect(manual.model == "pipeline-polish-manual-latest")
        #expect(manual.systemText == "排队之后修改的提示词。")
        #expect(try fixture.app.history().first { $0.id == first }?.polish?.attemptID != oldAttempt)
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        fixture.server.replyChat(manual, content: "History revision.")
        let secondPolish = try await fixture.request(.polish, raw: "I go second.")
        #expect(fixture.delivery.document.string == "Original delivery.")
        #expect(try fixture.app.currentText(first) == "History revision.")
        try fixture.app.copyCurrentText(first)
        #expect(fixture.delivery.copied == "History revision.")
        try fixture.app.copyRawTranscription(first)
        #expect(fixture.delivery.copied == "I go yesterday.")
        fixture.server.replyChat(secondPolish, content: "Second delivery.")
        try await pipelineWait { fixture.delivery.document.string == "Original delivery.Second delivery." }
        #expect(try fixture.app.history().first { $0.id == second }?.disposition == .completed)
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 2)
        #expect(fixture.server.requests.filter { $0.role == .coach }.isEmpty)
    }

    @Test
    func currentCandidateCopyDoesNotReleaseHeadAndManualInsertionStillProtectsFIFO() async throws {
        let fixture = try PipelineFixture(coachEnabled: false)
        defer { fixture.remove() }
        let first = try await fixture.record()
        let firstASR = try await fixture.request(.asr)
        let second = try await fixture.record()
        let secondASR = try await fixture.request(.asr, ordinal: 1)
        fixture.server.reply(secondASR, object: ["text": "Raw B."])
        fixture.server.reply(firstASR, object: ["text": "Raw A."])
        let firstPolish = try await fixture.request(.polish, raw: "Raw A."), secondPolish = try await fixture.request(.polish, raw: "Raw B.")
        fixture.server.replyChat(secondPolish, content: "Final B.")
        fixture.delivery.acceptsTarget = false
        fixture.server.replyChat(firstPolish, content: "Final A.")
        try await pipelineWait { (try? fixture.app.queue().first?.stage) == .awaitingManualDelivery }
        try fixture.app.copyCurrentText(first)
        #expect(fixture.delivery.copied == "Final A.")
        #expect(try fixture.app.queue().first?.id == first)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(throws: DictationError.outOfOrderDelivery) { try fixture.app.insertCurrentTextAtCurrentCursor(second) }
        #expect(try fixture.app.insertCurrentTextAtCurrentCursor(first) == .delivered)
        #expect(fixture.delivery.document.string == "Final A.")
        #expect(try fixture.app.queue().first?.id == second)
        try fixture.app.confirmManuallyDelivered(second)
        #expect(try fixture.app.queue().isEmpty)
    }

    @Test(arguments: PipelineInvalidation.allCases)
    func cancellationDeletionStopAndExitInvalidateBothRolesAndRejectLateResults(_ action: PipelineInvalidation) async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        try action.apply(to: fixture.app, id: id)
        try await pipelineWait { fixture.server.disconnected(polish) && fixture.server.disconnected(coach) }
        fixture.server.replyChat(polish, content: "Late polished result.")
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.server.requests.count == 3)
        if action == .delete { #expect(try fixture.app.history().isEmpty) }
        else {
            let entry = try #require(fixture.app.history().first)
            #expect(entry.rawTranscription == "I go yesterday.")
            #expect(entry.polishedText == nil)
            #expect(entry.coach?.result == nil)
            if action == .cancel { #expect(entry.disposition == .cancelled) }
        }
        if action == .stop {
            try fixture.app.repolish(id)
            let fresh = try await fixture.request(.polish, ordinal: 1)
            fixture.server.replyChat(fresh, content: "Explicit history revision.")
            try await pipelineWait { (try? fixture.app.currentText(id)) == "Explicit history revision." }
            #expect(fixture.delivery.document.string.isEmpty)
            #expect(fixture.server.requests.filter { $0.role == .coach }.count == 1)
        } else if action == .prepare {
            #expect(await fixture.app.startRecording() == false)
            #expect(throws: DictationError.applicationTerminating) { try fixture.app.repolish(id) }
            #expect(throws: DictationError.applicationTerminating) { try fixture.app.insertRawTranscriptionAtCurrentCursor(id) }
            #expect(throws: DictationError.applicationTerminating) { try fixture.app.insertCurrentTextAtCurrentCursor(id) }
        }
    }

    @Test(arguments: PipelineInvalidation.allCases)
    func invalidatingAManualRepolishKeepsTheAlreadyDeliveredDocumentAndPriorArtifact(_ action: PipelineInvalidation) async throws {
        let fixture = try PipelineFixture(coachEnabled: false)
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Original raw."])
        fixture.server.replyChat(try await fixture.request(.polish), content: "Delivered original.")
        try await pipelineWait { fixture.delivery.document.string == "Delivered original." }
        try fixture.app.repolish(id)
        let manual = try await fixture.request(.polish, ordinal: 1)
        try action.apply(to: fixture.app, id: id)
        try await pipelineWait { fixture.server.disconnected(manual) }
        fixture.server.replyChat(manual, content: "Late manual revision.")
        fixture.app.configurationChanged()
        #expect(fixture.delivery.document.string == "Delivered original.")
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 1)
        #expect(fixture.server.requests.filter { $0.role == .polish }.count == 2)
        if action == .delete { #expect(try fixture.app.history().isEmpty) }
        else { #expect(try fixture.app.history().first?.polishedText == "Delivered original.") }
    }

    @Test
    func preparePermanentlyRejectsBothManualInsertionEntrypointsBeforeWritingADocument() async throws {
        let fixture = try PipelineFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.delivery.acceptsTarget = false
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Saved raw before exit."])
        try await pipelineWait { (try? fixture.app.queue().first?.stage) == .awaitingManualDelivery }
        fixture.app.prepareForTermination()
        #expect(throws: DictationError.applicationTerminating) { try fixture.app.insertRawTranscriptionAtCurrentCursor(id) }
        #expect(throws: DictationError.applicationTerminating) { try fixture.app.insertCurrentTextAtCurrentCursor(id) }
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(try fixture.app.history().first?.disposition == .awaitingProcessing)
    }

    @Test
    func failedEncryptedResultPersistencePreventsDeliveryAndCardsWithoutAutomaticResending() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        let directory = fixture.history.appendingPathComponent("history/\(id)")
        let before = try savedFiles(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        fixture.server.replyChat(polish, content: "Unsaved polished result.")
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { fixture.app.mainRequestBudget.activeCount == 0 && fixture.app.coachScheduler?.inFlightCount == 0 }
        let entry = try #require(fixture.app.history().first)
        #expect(entry.rawTranscription == "I go yesterday.")
        #expect(entry.polishedText == nil)
        #expect(entry.polish?.failure == .storageFailure)
        #expect(entry.coach?.failure == .storageFailure)
        #expect(entry.coach?.result == nil)
        #expect(try savedFiles(directory) == before)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fixture.app.configurationChanged()
        #expect(fixture.server.requests.count == 3)
        #expect(fixture.delivery.document.string.isEmpty)
    }

    @Test(arguments: [false, true])
    func savingAValidCoachResultCanTurnOffTheSameSwitchAndOnlyPreserveHistory(_ disable: Bool) async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        _ = try await fixture.request(.polish)
        let coach = try await fixture.request(.coach)
        if disable {
            fixture.capacity.onCheck = {
                fixture.capacity.onCheck = nil
                try! fixture.app.coachScheduler?.setEnabled(false)
            }
        }
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { (try? fixture.app.history().first?.coach?.status) == .succeeded }
        #expect(try fixture.app.history().first?.coach?.result != nil)
        #expect(fixture.app.coachScheduler?.panelState.cards.count == (disable ? 0 : 1))
        try fixture.app.coachScheduler?.setEnabled(false)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
        try fixture.app.coachScheduler?.setEnabled(true)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
        #expect(fixture.server.requests.filter { $0.role == .coach }.count == 1)
        #expect(try fixture.app.history().first { $0.id == first }?.coach?.result != nil)
        let second = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr, ordinal: 1), object: ["text": "I go again."])
        let newCoach = try await fixture.request(.coach, raw: "I go again.")
        fixture.server.replyChat(newCoach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { fixture.app.coachScheduler?.panelState.cards.count == 1 }
        #expect(fixture.app.coachScheduler?.panelState.cards.first?.id == second)
    }

    @Test(arguments: [24 * 3_600.0, 24 * 3_600.0 + 1])
    func defaultSendingWindowAppliesToUnsentPolishAndCoachAndExplicitResumeRenewsIt(_ elapsed: TimeInterval) async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        try fixture.polishSettings.save(PolishConfiguration(enabled: true))
        try fixture.coachSettings.save(CoachConfiguration(enabled: true))
        fixture.app.configurationChanged()
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        try await pipelineWait { (try? fixture.app.history().first?.polish?.status) == .waitingForConfiguration }
        let recordedAt = try #require(fixture.app.history().first?.recordedAt)
        fixture.clock.date.addTimeInterval(elapsed)
        try fixture.polishSettings.save(PolishConfiguration(enabled: true, role: .init(serviceID: fixture.serviceID, model: "pipeline-polish-renewed")))
        try fixture.coachSettings.save(CoachConfiguration(enabled: true, role: .init(serviceID: fixture.serviceID, model: "pipeline-coach-renewed")))
        fixture.app.configurationChanged()
        if elapsed > 24 * 3_600 {
            #expect(try fixture.app.queue().first?.stage == .waitingForResume)
            #expect(try fixture.app.history().first?.coach?.status == .waitingForResume)
            #expect(fixture.server.requests.count == 1)
            try fixture.app.resumePendingProcessing(id)
            #expect(try fixture.app.history().first?.automaticSendingStartedAt == fixture.clock.date)
        }
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        #expect(polish.model == "pipeline-polish-renewed")
        #expect(coach.model == "pipeline-coach-renewed")
        #expect(try fixture.app.history().first?.recordedAt == recordedAt)
        fixture.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        fixture.server.replyChat(polish, content: "Resumed ordered text.")
        try await pipelineWait { fixture.delivery.document.string == "Resumed ordered text." }
    }

    @Test
    func unfinishedHistorySurvivesRetentionAndExplicitDeletionCancelsPendingRoles() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        fixture.server.replyChat(polish, content: "Delivered before retention.")
        try await pipelineWait { fixture.delivery.document.string == "Delivered before retention." }
        try fixture.app.repolish(id)
        let manual = try await fixture.request(.polish, ordinal: 1)
        var recursiveReads = 0
        fixture.app.onChange = {
            recursiveReads += 1
            if recursiveReads < 4 { _ = try? fixture.app.history() }
        }
        fixture.clock.date.addTimeInterval(31 * 86_400)
        #expect(try fixture.app.history().contains { $0.id == id })
        #expect(!fixture.server.disconnected(manual) && !fixture.server.disconnected(coach))
        try fixture.app.deleteHistory(id)
        #expect(try fixture.app.history().isEmpty)
        #expect(recursiveReads < 4)
        try await pipelineWait { fixture.server.disconnected(manual) && fixture.server.disconnected(coach) }
        fixture.server.replyChat(manual, content: "Late after retention.")
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        #expect(try fixture.app.history().isEmpty)
        #expect(fixture.delivery.document.string == "Delivered before retention.")
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
    }

    @Test
    func olderEncryptedEntriesDecodeWithoutInventingPolishOrCoachArtifacts() async throws {
        let fixture = try PipelineFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Older saved raw."])
        try await pipelineWait { fixture.delivery.document.string == "Older saved raw." }
        let path = fixture.history.appendingPathComponent("history/\(id)/entry.enc")
        let key = SymmetricKey(data: TestDataKey().bytes), context = Data("\(id)/entry".utf8)
        let encrypted = try Data(contentsOf: path)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted.dropFirst(6)), using: key, authenticating: context)
        var metadata = try #require(JSONSerialization.jsonObject(with: clear) as? [String: Any])
        var entry = try #require(metadata["entry"] as? [String: Any])
        for field in ["recordingEndedAt", "automaticSendingStartedAt", "polishedText", "polish", "coach"] { entry[field] = nil }
        metadata["entry"] = entry
        let sealed = try #require(AES.GCM.seal(JSONSerialization.data(withJSONObject: metadata), using: key, authenticating: context).combined)
        try (Data("QDENC1".utf8) + sealed).write(to: path, options: .atomic)
        let reopened = RecordingApplication(source: PipelineMicrophone(), historyDirectory: fixture.history, keys: TestDataKey())
        let restored = try #require(reopened.history().first)
        #expect(restored.rawTranscription == "Older saved raw.")
        #expect(restored.recordingEndedAt == nil)
        #expect(restored.polishedText == nil)
        #expect(restored.polish == nil)
        #expect(restored.coach == nil)
    }

    @Test
    func stoppingInsideAnObserverRejectsStackLocalWorkAndAllowsANewExplicitAttemptAfterReturn() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        _ = try await fixture.request(.polish)
        _ = try await fixture.request(.coach)
        var attempted = false, accepted = false
        fixture.app.onChange = {
            guard !attempted else { return }
            attempted = true
            do { try fixture.app.repolish(id); accepted = true } catch {}
        }
        fixture.app.stopProcessing()
        fixture.app.onChange = nil
        #expect(attempted)
        #expect(!accepted)
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        try fixture.app.repolish(id)
        let fresh = try await fixture.request(.polish, ordinal: 1)
        fixture.server.replyChat(fresh, content: "New explicit history result.")
        try await pipelineWait { (try? fixture.app.currentText(id)) == "New explicit history result." }
        #expect(fixture.delivery.document.string.isEmpty)
    }

    @Test
    func increasingTheConfiguredWindowDoesNotSilentlyResumeAlreadyExpiredPolishOrCoach() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        try fixture.resources.save(ResourceConfiguration(automaticSendingWindow: 3_600))
        try fixture.polishSettings.save(PolishConfiguration(enabled: true))
        try fixture.coachSettings.save(CoachConfiguration(enabled: true))
        fixture.app.configurationChanged()
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        try await pipelineWait { (try? fixture.app.history().first?.polish?.status) == .waitingForConfiguration }
        fixture.clock.date.addTimeInterval(3_601)
        try fixture.polishSettings.save(PolishConfiguration(enabled: true, role: .init(serviceID: fixture.serviceID, model: "pipeline-polish")))
        try fixture.coachSettings.save(CoachConfiguration(enabled: true, role: .init(serviceID: fixture.serviceID, model: "pipeline-coach")))
        fixture.app.configurationChanged()
        #expect(try fixture.app.queue().first?.stage == .waitingForResume)
        try fixture.resources.save(ResourceConfiguration(automaticSendingWindow: 7_200))
        fixture.app.configurationChanged()
        #expect(try fixture.app.queue().first?.stage == .waitingForResume)
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        #expect(fixture.app.coachScheduler?.inFlightCount == 0)
        try fixture.app.resumePendingProcessing(id)
        fixture.server.replyChat(try await fixture.request(.polish), content: "Explicitly resumed text.")
        fixture.server.replyChat(try await fixture.request(.coach), content: "{\"kind\":\"no_card\"}")
        try await pipelineWait { fixture.delivery.document.string == "Explicitly resumed text." }
    }

    @Test(arguments: PipelineBeforeSend.allCases, PipelineInvalidation.allCases)
    func invalidationDuringPersistenceCannotStartTheOldPolishOrCoachRequest(_ phase: PipelineBeforeSend, _ action: PipelineInvalidation) async throws {
        let fixture = try PipelineFixture(coachEnabled: phase == .coach)
        defer { fixture.remove() }
        let id = try await fixture.record()
        let asr = try await fixture.request(.asr)
        var invalidated = false
        fixture.capacity.onCheck = {
            guard let entry = try? fixture.app.history().first, entry.rawTranscription != nil else { return }
            fixture.capacity.onCheck = nil
            invalidated = true
            try! action.apply(to: fixture.app, id: id)
        }
        fixture.server.reply(asr, object: ["text": "I go yesterday."])
        try await pipelineWait { invalidated && fixture.app.mainRequestBudget.activeCount == 0 }
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
        if action == .delete { #expect(try fixture.app.history().isEmpty) }
        if action == .stop {
            let fresh = try await fixture.record()
            fixture.server.reply(try await fixture.request(.asr, ordinal: 1), object: ["text": "Fresh raw."])
            fixture.server.replyChat(try await fixture.request(.polish), content: "Fresh delivery.")
            try await pipelineWait { (try? fixture.app.history().first { $0.id == fresh }?.polishedText) == "Fresh delivery." }
            #expect(try fixture.app.queue().first?.id == id)
            #expect(fixture.delivery.document.string.isEmpty)
            try fixture.app.skipMainDelivery(id)
            try await pipelineWait { fixture.delivery.document.string == "Fresh delivery." }
            #expect(try fixture.app.history().first { $0.id == fresh }?.disposition == .completed)
        }
    }

    @Test
    func rawPersistenceFailurePreventsBothDownstreamModelRequests() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        let asr = try await fixture.request(.asr)
        let directory = fixture.history.appendingPathComponent("history/\(id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        fixture.server.reply(asr, object: ["text": "Raw cannot be saved."])
        try await pipelineWait { fixture.app.mainRequestBudget.activeCount == 0 }
        #expect(try fixture.app.history().first?.rawTranscription == nil)
        #expect(try fixture.app.history().first?.transcription?.failure == .storageFailure)
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.app.coachScheduler?.panelState.cards.isEmpty == true)
    }

    @Test
    func theUnsentASRWindowStartsAtRecordingEndRatherThanRecordingStart() async throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        var configuration = try fixture.services.load()
        configuration.transcription = nil
        try fixture.services.save(configuration)
        let startedAt = fixture.clock.date
        #expect(await fixture.app.startRecording())
        guard case .recording(let id, _) = fixture.app.state else { throw PipelineTestError.recording }
        fixture.source.emit(testAudio())
        fixture.clock.date.addTimeInterval(60)
        await fixture.app.finishRecording()
        #expect(try fixture.app.history().first?.recordedAt == startedAt)
        #expect(try fixture.app.history().first?.recordingEndedAt == startedAt.addingTimeInterval(60))
        fixture.clock.date.addTimeInterval(24 * 3_600)
        configuration.transcription = .init(serviceID: fixture.serviceID, model: "pipeline-asr")
        try fixture.services.save(configuration)
        fixture.app.configurationChanged()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Actual ended-time anchor."])
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        fixture.server.replyChat(polish, content: "Text within the end-time window.")
        fixture.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        try await pipelineWait { fixture.delivery.document.string == "Text within the end-time window." }
        #expect(try fixture.app.history().first?.id == id)
        #expect(try fixture.app.history().first?.recordedAt == startedAt)
    }

    @Test
    func clearlyChineseRawSkipsCoachWhileMixedRawUsesOneIndependentModelRequest() async throws {
        let fixture = try PipelineFixture(polishEnabled: false)
        defer { fixture.remove() }
        let chinese = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "这是一段纯中文口述。"])
        try await pipelineWait { fixture.delivery.document.string == "这是一段纯中文口述。" }
        #expect(fixture.server.requests.filter { $0.role == .coach }.isEmpty)
        #expect(try fixture.app.history().first { $0.id == chinese }?.coach == nil)
        let mixed = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr, ordinal: 1), object: ["text": "I go yesterday，今天继续。"])
        let coach = try await fixture.request(.coach)
        #expect(coach.userText == "I go yesterday，今天继续。")
        fixture.server.replyChat(coach, content: pipelineCard(original: "I go", improved: "I went"))
        try await pipelineWait { fixture.app.coachScheduler?.panelState.cards.count == 1 }
        #expect(fixture.app.coachScheduler?.panelState.cards.first?.id == mixed)
        #expect(fixture.server.requests.filter { $0.role == .coach }.count == 1)
        #expect(fixture.server.requests.filter { $0.role == .polish }.isEmpty)
    }

    @Test
    func unreadableCoachConfigurationRemainsVisibleUntilTheSharedConfigurationIsRepaired() throws {
        let fixture = try PipelineFixture()
        defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent("coach.json")
        try Data("invalid-coach-configuration".utf8).write(to: path)
        let app = RecordingApplication(source: PipelineMicrophone(), historyDirectory: fixture.history, keys: TestDataKey(),
            coach: CoachDependencies(settings: fixture.coachSettings, services: fixture.services, credentials: fixture.credentials))
        defer { app.stopProcessing() }
        app.configurationChanged()
        #expect(app.coachScheduler == nil)
        #expect(app.coachConfigurationFailure == .invalidConfiguration)
        #expect(try Data(contentsOf: path) == Data("invalid-coach-configuration".utf8))
        #expect(fixture.server.requests.isEmpty)
        try fixture.coachSettings.save(CoachConfiguration())
        app.configurationChanged()
        #expect(app.coachScheduler != nil)
        #expect(app.coachConfigurationFailure == nil)
    }
}

@MainActor
private final class PipelineFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-pipeline-\(UUID())")
    let source = PipelineMicrophone()
    let server: PipelineLoopbackServer
    let credentials = TestServiceCredentials()
    let services: ServiceSettings
    let polishSettings: PolishSettings
    let coachSettings: CoachSettings
    let resources: ResourceSettings
    let timing = ControlledRequestTiming()
    let clock = PipelineClock()
    let capacity = PipelineCapacity()
    let delivery = PipelineDocumentDelivery()
    let serviceID = UUID()
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }

    init(polishEnabled: Bool = true, coachEnabled: Bool = true, concurrency: Int = 3) throws {
        server = try PipelineLoopbackServer()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        polishSettings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        coachSettings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        resources = ResourceSettings(file: root.appendingPathComponent("resources.json"))
        let service = ModelService(id: serviceID, name: "合成口述 loopback", baseURL: server.baseURL, authentication: .bearerToken)
        try services.save(ModelConfiguration(services: [service], transcription: .init(serviceID: serviceID, model: "pipeline-asr")))
        try credentials.saveKey("pipeline-fake-key", for: serviceID)
        try polishSettings.save(PolishConfiguration(enabled: polishEnabled, role: .init(serviceID: serviceID, model: "pipeline-polish"), customPrompt: "完整润色提示词，仅整理本段。"))
        try coachSettings.save(CoachConfiguration(enabled: coachEnabled, role: .init(serviceID: serviceID, model: "pipeline-coach"), customPrompt: "完整文本带教提示词，不评流利度。"))
        let clock = self.clock, capacity = self.capacity
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            now: { clock.date },
            diskSpace: { _ in capacity.onCheck?(); return capacity.bytes },
            transcription: TranscriptionDependencies(settings: services, credentials: credentials, delivery: delivery, timing: timing),
            polish: PolishClient(settings: polishSettings, services: services, credentials: credentials, timing: timing),
            coach: CoachDependencies(settings: coachSettings, services: services, credentials: credentials, timing: timing),
            resourceSettings: resources)
        try app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency))
    }

    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw PipelineTestError.recording }
        source.emit(testAudio())
        await app.finishRecording()
        return id
    }

    func request(_ role: PipelineRole, raw: String? = nil, ordinal: Int = 0) async throws -> PipelineLoopbackServer.Request {
        try await pipelineWait { self.server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }.count > ordinal }
        return server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }[ordinal]
    }

    func remove() {
        capacity.onCheck = nil; app.onChange = nil
        app.stopProcessing(); source.stop(); timing.cancelAll(); server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PipelineClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
private final class PipelineCapacity {
    var bytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
    var onCheck: (() -> Void)?
}

@MainActor
private final class PipelineMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { stream = $0 } }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}

@MainActor
private final class PipelineDocumentDelivery: TextDelivering {
    let document = NSTextView()
    var copied = "等待时用户新复制的内容"
    var onDeliver: (() -> Void)?
    var acceptsTarget = true
    private struct Snapshot { var text: String; var range: NSRange }
    private var targets: [UUID: Snapshot] = [:]
    func captureTarget() -> TextDeliveryTarget? {
        let target = TextDeliveryTarget()
        targets[target.id] = Snapshot(text: document.string, range: document.selectedRange())
        return target
    }
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard acceptsTarget, let before = targets[target.id], before.text == document.string,
              before.range == document.selectedRange() else { return .manual }
        onDeliver?()
        document.insertText(text, replacementRange: document.selectedRange())
        for (id, saved) in targets where saved.text == before.text && saved.range == before.range {
            targets[id] = Snapshot(text: document.string, range: document.selectedRange())
        }
        return .delivered
    }
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult {
        document.insertText(text, replacementRange: document.selectedRange())
        return .delivered
    }
    func releaseTarget(_ target: TextDeliveryTarget) { targets[target.id] = nil }
    func copy(_ text: String) { copied = text }
}

private enum PipelineRole { case asr, polish, coach }

private final class PipelineLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let path: String
        let authorization: String?
        let body: Data
        private var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var role: PipelineRole { path.hasSuffix("audio/transcriptions") ? .asr : model.contains("coach") ? .coach : .polish }
        var model: String { json?["model"] as? String ?? "" }
        var jsonKeys: Set<String> { Set(json?.keys.map { $0 } ?? []) }
        var userText: String? { (json?["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "user" }?["content"] as? String }
        var systemText: String? { (json?["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "system" }?["content"] as? String }
    }
    private let lock = NSLock()
    private let listener: Int32
    private var captured: [Request] = []
    private var connections: [Int: Int32] = [:]
    private var closed: Set<Int> = []
    private var stopped = false
    let baseURL: String
    var requests: [Request] { lock.withLock { captured } }
    func disconnected(_ request: Request) -> Bool { lock.withLock { closed.contains(request.index) } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw PipelineTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 32) == 0 else { close(descriptor); throw PipelineTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw PipelineTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "model-pipeline-loopback").async { [self] in
            defer { close(descriptor) }
            while !lock.withLock({ stopped }) {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }

    func reply(_ request: Request, object: [String: Any], status: Int = 200) {
        reply(request, body: try! JSONSerialization.data(withJSONObject: object), status: status)
    }
    func replyChat(_ request: Request, content: String, status: Int = 200) {
        reply(request, object: ["choices": [["message": ["content": content]]]], status: status)
    }
    func reply(_ request: Request, body: Data, status: Int = 200) {
        let header = Data("HTTP/1.1 \(status) Controlled\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        lock.withLock {
            guard let connection = connections[request.index] else { return }
            (header + body).withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = send(connection, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { break }
                    sent += count
                }
            }
            shutdown(connection, SHUT_RDWR)
        }
    }
    func stop() {
        lock.withLock {
            stopped = true
            shutdown(listener, SHUT_RDWR)
            connections.values.forEach { shutdown($0, SHUT_RDWR) }
        }
    }

    private func receive(_ connection: Int32) {
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?, expected = 0, path = "", authorization: String?
        while bytes.count < 4 * 1_024 * 1_024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { close(connection); return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
               let header = String(data: bytes.prefix(end), encoding: .utf8) {
                headerEnd = end
                let lines = header.components(separatedBy: "\r\n")
                path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
                expected = lines.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst(14).trimmingCharacters(in: .whitespaces)) }
            }
            if let end = headerEnd, bytes.count - end >= expected {
                let index = lock.withLock {
                    let index = captured.count
                    captured.append(Request(index: index, path: path, authorization: authorization, body: Data(bytes.dropFirst(end).prefix(expected))))
                    connections[index] = connection
                    if stopped { shutdown(connection, SHUT_RDWR) }
                    return index
                }
                while recv(connection, &buffer, buffer.count, 0) > 0 {}
                lock.withLock { connections[index] = nil; closed.insert(index); close(connection) }
                return
            }
        }
        close(connection)
    }
}

private func pipelineCard(original: String, improved: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["kind": "card", "suggestions": [["category": "grammar", "original": original, "improved": improved, "reason": "昨天发生的动作应使用过去式。"]]]), encoding: .utf8)!
}

@MainActor
private func pipelineWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw PipelineTestError.wait }
        await Task.yield()
    }
}

private enum PipelineTestError: Error { case socket, recording, wait }

struct PipelinePolishFailure: Sendable { let status: Int; let body: String; let failure: PolishFailure }

enum PipelineInvalidation: CaseIterable, Sendable {
    case cancel, delete, stop, prepare
    @MainActor
    func apply(to app: RecordingApplication, id: UUID) throws {
        switch self {
        case .cancel: try app.cancelRecordedSegment(id)
        case .delete: try app.deleteHistory(id)
        case .stop: app.stopProcessing()
        case .prepare: app.prepareForTermination()
        }
    }
}

enum PipelineBeforeSend: CaseIterable, Sendable { case polish, coach }
