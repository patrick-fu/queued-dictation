import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DictationCore

@Suite(.serialized)
@MainActor
struct RuntimeResourceBehaviorTests {
    @Test(arguments: [RuntimeInvalidation.prepare, .cancel, .stop])
    func manualInsertionDoesNotWriteAfterItsSlotReleaseObserverInvalidatesTheWork(_ action: RuntimeInvalidation) async throws {
        let fixture = try RuntimeFixture(coachEnabled: false, concurrency: 1)
        defer { fixture.remove() }
        let first = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Old raw A."])
        let oldPolish = try await fixture.request(.polish)
        _ = try await fixture.record()
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 1)
        var invalidated = false
        fixture.app.onChange = {
            guard !invalidated else { return }
            invalidated = true
            try! action.apply(to: fixture.app, id: first)
        }
        do { _ = try fixture.app.insertRawTranscriptionAtCurrentCursor(first) }
        catch { #expect(error is DictationError) }
        fixture.app.onChange = nil
        #expect(invalidated)
        #expect(fixture.delivery.document.string.isEmpty)
        let after = try #require(fixture.app.history().first { $0.id == first })
        #expect(after.delivery != .delivered)
        #expect(after.rawTranscription == "Old raw A.")
        try await runtimeWait { fixture.server.disconnected(oldPolish) }
    }

    @Test(arguments: [false, true])
    func manualHistoricalRepolishNeedsExplicitResumeAfterExpiryEvenWhenTheWindowIsWidened(_ initiallyManual: Bool) async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.delivery.acceptsTarget = !initiallyManual
        try fixture.resources.save(ResourceConfiguration(automaticSendingWindow: 3_600))
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Window probe raw."])
        try await runtimeWait { (try? fixture.app.history().first?.rawTranscription) != nil && fixture.app.mainRequestBudget.activeCount == 0 }
        let originalDocument = fixture.delivery.document.string
        let originalDisposition = try #require(fixture.app.history().first?.disposition)
        try fixture.polishSettings.save(PolishConfiguration(enabled: true))
        try fixture.app.repolish(id)
        #expect(try fixture.app.history().first?.polish?.status == .waitingForConfiguration)
        let previousAnchor = try #require(fixture.app.history().first?.automaticSendingStartedAt)
        fixture.clock.date.addTimeInterval(3_601)
        fixture.app.configurationChanged()
        #expect(try fixture.app.history().first?.queueStage == .waitingForResume)
        try fixture.resources.save(ResourceConfiguration(automaticSendingWindow: 7_200))
        try fixture.polishSettings.save(PolishConfiguration(enabled: true, role: .init(serviceID: fixture.serviceID, model: "runtime-polish")))
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        #expect(try fixture.app.history().first?.queueStage == .waitingForResume)
        #expect(try fixture.app.history().first?.automaticSendingStartedAt == previousAnchor)
        try fixture.app.resumePendingProcessing(id)
        let sent = try await fixture.request(.polish)
        #expect(sent.userText == "Window probe raw.")
        fixture.server.replyChat(sent, content: "History revision.")
        try await runtimeWait { (try? fixture.app.currentText(id)) == "History revision." }
        #expect(try fixture.app.history().first?.disposition == originalDisposition)
        #expect(fixture.delivery.document.string == originalDocument)
        #expect(fixture.server.requests.filter { $0.role == .polish }.count == 1)
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 1)
    }
    @Test
    func explicitResourceSettingsOverrideInjectedLimitsAndApplyToEachNewRecording() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        try fixture.resources.save(ResourceConfiguration(maximumPendingSegments: 1))
        let first = try await fixture.record()
        _ = try await fixture.request(.asr)
        #expect(await fixture.app.startRecording() == false)
        #expect(try fixture.app.history().map(\.id) == [first])
        try fixture.resources.save(ResourceConfiguration(maximumPendingSegments: 2))
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        #expect(try fixture.app.history().count == 2)
        try fixture.resources.save(ResourceConfiguration(maximumPendingSegments: 1))
        #expect(await fixture.app.startRecording() == false)
        #expect(try fixture.app.history().count == 2)
    }

    @Test(arguments: [false, true])
    func reducedRecordingDurationTruncatesTheNextPCMChunkAndKeepsTheSavedPrefix(_ pendingDurationIsFirst: Bool) async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        #expect(await fixture.app.startRecording())
        let first = PCMChunk(samples: Data(repeating: 21, count: 59 * 8_000 * 2), sampleRate: 8_000)
        fixture.source.emit(first)
        try await runtimeWait { if case .recording(_, let duration) = fixture.app.state { return duration == 59 }; return false }
        try fixture.resources.save(ResourceConfiguration(maximumPendingDuration: pendingDurationIsFirst ? 60 : 1_800, maximumRecordingDuration: pendingDurationIsFirst ? 300 : 60))
        fixture.source.emit(PCMChunk(samples: Data(repeating: 23, count: 3 * 8_000 * 2), sampleRate: 8_000))
        await fixture.app.finishRecording()
        let entry = try #require(fixture.app.history().first)
        #expect(entry.duration == 60)
        let exported = fixture.root.appendingPathComponent("prefix.wav")
        try fixture.app.exportAudio(entry.id, to: exported)
        let wave = try Data(contentsOf: exported)
        let expectedWaveBytes = 960_044
        #expect(wave.count == expectedWaveBytes)
        #expect(wave.dropFirst(44).prefix(first.samples.count) == first.samples)
        #expect(wave.suffix(8_000 * 2) == Data(repeating: 23, count: 8_000 * 2))
    }

    @Test
    func mainConcurrencyRejectsNonzeroFractionBeyondDecimalPrecisionWithoutChangingTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-main-integer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("processing.json")
        let bytes = Data("{\"maximumConcurrentMainRequests\":3.000000000000000000000000000000000000001}".utf8)
        try bytes.write(to: file)
        #expect(throws: ProcessingSettingsError.invalidConcurrency) { try ProcessingSettings(file: file).load() }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test
    func offlineAudioDoesNotConsumeADeadlineAndOnlyUnsentWorkResumesWithLatestKeys() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.network.setAvailable(false)
        let first = try await fixture.record(), second = try await fixture.record()
        fixture.timing.advance(to: 600)
        fixture.app.checkRecordingConditions()
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        #expect(try fixture.app.history().allSatisfy { $0.transcription?.status == .waitingForNetwork })
        try fixture.services.saveService(.init(id: fixture.serviceID, name: "在线最新服务", baseURL: fixture.server.baseURL + "/latest", authentication: .bearerToken),
            newKey: "runtime-latest-key", credentials: fixture.credentials)
        fixture.network.setAvailable(true)
        let one = try await fixture.request(.asr), two = try await fixture.request(.asr, ordinal: 1)
        #expect(one.path == "/latest/audio/transcriptions" && two.path == one.path)
        #expect(one.authorization == "Bearer runtime-latest-key" && two.authorization == one.authorization)
        fixture.server.reply(one, object: ["error": ["message": "private-error-body"]], status: 503)
        fixture.server.reply(two, object: ["text": "Second result."])
        try await runtimeWait { (try? fixture.app.history().first { $0.id == first }?.transcription?.status) == .failed && (try? fixture.app.rawTranscription(second)) == "Second result." }
        fixture.network.setAvailable(false); fixture.network.setAvailable(true)
        fixture.app.configurationChanged()
        #expect(fixture.server.requests.count == 2)
        #expect(fixture.delivery.document.string.isEmpty)
        try fixture.app.skipMainDelivery(first)
        #expect(fixture.delivery.document.string == "Second result.")
        #expect(fixture.app.notice?.contains("private-error-body") != true)
    }

    @Test
    func unsentPolishAndCoachWaitOfflineWithoutBlockingEachOtherOrUsingOldConfiguration() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        let asr = try await fixture.request(.asr)
        fixture.network.setAvailable(false)
        fixture.server.reply(asr, object: ["text": "I go yesterday."])
        try await runtimeWait { (try? fixture.app.history().first?.polish?.status) == .waitingForNetwork && (try? fixture.app.history().first?.coach?.status) == .waitingForNetwork }
        fixture.timing.advance(to: 600)
        fixture.app.configurationChanged()
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.app.mainRequestBudget.activeCount == 0 && fixture.app.coachScheduler?.inFlightCount == 0)
        try fixture.polishSettings.save(.init(enabled: true, role: .init(serviceID: fixture.serviceID, model: "runtime-polish-latest"), customPrompt: "最新润色完整提示词。"))
        try fixture.coachSettings.save(.init(enabled: true, role: .init(serviceID: fixture.serviceID, model: "runtime-coach-latest"), customPrompt: "最新带教完整提示词。"))
        try fixture.credentials.saveKey("runtime-role-latest-key", for: fixture.serviceID)
        fixture.network.setAvailable(true)
        let polish = try await fixture.request(.polish), coach = try await fixture.request(.coach)
        #expect(polish.authorization == "Bearer runtime-role-latest-key" && coach.authorization == polish.authorization)
        #expect(polish.model == "runtime-polish-latest" && coach.model == "runtime-coach-latest")
        #expect(polish.systemText == "最新润色完整提示词。" && coach.systemText == "最新带教完整提示词。")
        fixture.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        fixture.server.replyChat(polish, content: "I went yesterday.")
        try await runtimeWait { fixture.delivery.document.string == "I went yesterday." && (try? fixture.app.history().first?.coach?.status) == .succeeded }
        #expect(try fixture.app.currentText(id) == "I went yesterday.")
        #expect(fixture.server.requests.count == 3)
    }

    @Test(arguments: [false, true])
    func retryAfterDelaysOnlyUnsentRequestsAndDoesNotRetryTheFailedAttempt(_ useHTTPDate: Bool) async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false, concurrency: 1)
        defer { fixture.remove() }
        fixture.clock.date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await fixture.record()
        let failed = try await fixture.request(.asr)
        let second = try await fixture.record()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let actualHeader = !useHTTPDate ? "120" : formatter.string(from: fixture.clock.date.addingTimeInterval(120))
        fixture.server.reply(failed, object: ["error": ["message": "private retry body"]], status: 429, headers: ["Retry-After": actualHeader])
        try await runtimeWait { (try? fixture.app.history().first { $0.id == second }?.transcription?.status) == .waitingForBackoff }
        #expect(fixture.server.requests.count == 1)
        fixture.timing.advance(to: 119)
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        try fixture.credentials.saveKey("runtime-after-wait-key", for: fixture.serviceID)
        fixture.timing.advance(to: 120)
        let next = try await fixture.request(.asr, ordinal: 1)
        #expect(next.authorization == "Bearer runtime-after-wait-key")
        fixture.server.reply(next, object: ["text": "Next after cooldown."])
        try await runtimeWait { (try? fixture.app.rawTranscription(second)) == "Next after cooldown." }
        #expect(try fixture.app.history().first { $0.id == first }?.transcription?.status == .failed)
        #expect(fixture.server.requests.count == 2 && fixture.delivery.document.string.isEmpty)
        try fixture.app.skipMainDelivery(first)
        #expect(fixture.delivery.document.string == "Next after cooldown.")
    }

    @Test
    func localAccountingIncludesActiveHistoryAndExternallySavedEncryptedFavoritesWithoutDroppingRecordingReserves() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        let first = try await fixture.record()
        let request = try await fixture.request(.asr)
        let reserved = try fixture.app.reservedStorageBytes
        #expect(reserved > 1_048_576)
        let before = try fixture.app.storageUsage()
        let favorites = FavoritesStore(vaultRoot: fixture.history, keys: TestDataKey(), maximumLocalBytes: { try fixture.app.resourceConfiguration.maximumLocalBytes },
            diskSpace: { _ in fixture.capacity.bytes }, reservedBytes: { try fixture.app.reservedStorageBytes })
        favorites.onChange = { fixture.app.invalidateStorageUsage() }
        let favorite = FavoriteFeedback(rawText: "I go yesterday.", feedback: .init(suggestions: [.init(category: .grammar, original: "I go", improved: "I went", reason: "过去时。")]))
        try favorites.save(favorite)
        let withFavorite = try fixture.app.storageUsage()
        #expect(withFavorite > before)
        let encrypted = try Data(contentsOf: fixture.history.appendingPathComponent("favorites/\(favorite.id).enc"))
        #expect(encrypted.starts(with: Data("QDENC1".utf8)))
        #expect(encrypted.range(of: Data("I go yesterday.".utf8)) == nil)
        fixture.capacity.bytes = 65 * 1_024 * 1_024 + reserved - 1
        #expect(await fixture.app.startRecording() == false)
        #expect(try fixture.app.history().map(\.id) == [first])
        fixture.server.reply(request, object: ["text": "Safely reserved result."])
        try await runtimeWait { fixture.delivery.document.string == "Safely reserved result." }
        #expect(try fixture.app.reservedStorageBytes == 0)
        fixture.capacity.bytes = 100 * 1_024 * 1_024 * 1_024
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        try await runtimeWait { if case .recording(_, let duration) = fixture.app.state { return duration == 0.5 }; return false }
        let activeUsage = try fixture.app.storageUsage()
        #expect(activeUsage > withFavorite)
        fixture.app.invalidateStorageUsage()
        #expect(try fixture.app.storageUsage() == activeUsage)
        await fixture.app.cancelCurrentRecording()
        #expect(try favorites.entry(favorite.id) == favorite)
    }

    @Test
    func reducingTheWholeVaultLimitRejectsNewRecordingAndKeepsTheExistingVaultFiles() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.network.setAvailable(false)
        let id = try await fixture.record()
        let original = try Data(contentsOf: fixture.history.appendingPathComponent("history/\(id)/entry.enc"))
        _ = try fixture.app.storageUsage()
        let folder = fixture.history.appendingPathComponent("favorites")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reservedFile = folder.appendingPathComponent("generated-space.enc")
        try Data("QDENC1".utf8).write(to: reservedFile)
        let handle = try FileHandle(forWritingTo: reservedFile)
        try handle.truncate(atOffset: 1_073_741_824); try handle.close()
        fixture.app.invalidateStorageUsage()
        try fixture.resources.save(.init(maximumLocalBytes: 1_073_741_824))
        #expect(await fixture.app.startRecording() == false)
        #expect(try Data(contentsOf: fixture.history.appendingPathComponent("history/\(id)/entry.enc")) == original)
        #expect(FileManager.default.fileExists(atPath: reservedFile.path))
        #expect(try fixture.app.history().count == 1)
        try FileManager.default.removeItem(at: reservedFile)
        fixture.app.invalidateStorageUsage()
        #expect(await fixture.app.startRecording())
        await fixture.app.cancelCurrentRecording()
    }

    @Test
    func retryAfterFromPolishGatesPendingASRButAnEditedEndpointHasItsOwnScope() async throws {
        let fixture = try RuntimeFixture(coachEnabled: false, concurrency: 1)
        defer { fixture.remove() }
        let first = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "Raw A."])
        let polish = try await fixture.request(.polish)
        let second = try await fixture.record()
        fixture.server.reply(polish, object: ["error": ["message": "private body"]], status: 503, headers: ["Retry-After": "120"])
        try await runtimeWait { (try? fixture.app.history().first { $0.id == second }?.transcription?.status) == .waitingForBackoff }
        #expect(fixture.delivery.document.string == "Raw A.")
        #expect(try fixture.app.history().first { $0.id == first }?.polish?.status == .failed)
        try fixture.coachSettings.save(.init(enabled: true, role: .init(serviceID: fixture.serviceID, model: "runtime-coach")))
        fixture.app.configurationChanged()
        let third = try await fixture.record()
        try fixture.services.saveService(.init(id: fixture.serviceID, name: "新的端点路径", baseURL: fixture.server.baseURL + "/new", authentication: .bearerToken), newKey: nil, credentials: fixture.credentials)
        fixture.app.configurationChanged()
        let next = try await fixture.request(.asr, ordinal: 1)
        #expect(next.path == "/new/audio/transcriptions")
        fixture.server.reply(next, object: ["text": "I go B."])
        let coach = try await fixture.request(.coach)
        #expect(coach.path == "/new/chat/completions")
        fixture.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        let polishB = try await fixture.request(.polish, raw: "I go B.")
        fixture.server.replyChat(polishB, content: "B.")
        _ = try await fixture.request(.asr, ordinal: 2)
        #expect(try fixture.app.queue().contains { $0.id == third })
        #expect(fixture.delivery.document.string == "Raw A.B.")
        #expect(fixture.server.requests.filter { $0.role == .polish && $0.userText == "Raw A." }.count == 1)
    }

    @Test(arguments: [RuntimeInvalidation.prepare, .cancel, .stop])
    func aNetworkWakeDoesNotRestartInvalidatedUnsentRoles(_ action: RuntimeInvalidation) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        let request = try await fixture.request(.asr)
        fixture.network.setAvailable(false)
        fixture.server.reply(request, object: ["text": "I go yesterday."])
        try await runtimeWait { (try? fixture.app.history().first?.polish?.status) == .waitingForNetwork }
        try action.apply(to: fixture.app, id: id)
        fixture.network.setAvailable(true)
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 0 && fixture.app.coachScheduler?.inFlightCount == 0)
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.delivery.document.string.isEmpty)
        if action == .prepare {
            #expect(throws: DictationError.applicationTerminating) { try fixture.app.repolish(id) }
        }
    }

    @Test
    func pendingCoachExpiryIsObservedEvenWhenItsPoolIsFullAndDoesNotReplayMainDelivery() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false)
        defer { fixture.remove() }
        var config = try fixture.coachSettings.load(); config.concurrency = 1
        try fixture.coachSettings.save(config)
        try fixture.resources.save(.init(automaticSendingWindow: 3_600))
        fixture.app.configurationChanged()
        let first = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go A."])
        let firstCoach = try await fixture.request(.coach)
        let second = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr, ordinal: 1), object: ["text": "I go B."])
        try await runtimeWait { fixture.delivery.document.string == "I go A.I go B." && fixture.app.coachScheduler?.pendingCount == 1 }
        fixture.clock.date.addTimeInterval(3_601)
        fixture.app.checkRecordingConditions()
        #expect(try fixture.app.history().first { $0.id == second }?.coach?.status == .waitingForResume)
        try fixture.resources.save(.init(automaticSendingWindow: 7_200))
        fixture.server.replyChat(firstCoach, content: "{\"kind\":\"no_card\"}")
        try await runtimeWait { fixture.app.coachScheduler?.inFlightCount == 0 }
        #expect(fixture.server.requests.filter { $0.role == .coach }.count == 1)
        try fixture.app.resumePendingProcessing(second)
        fixture.server.replyChat(try await fixture.request(.coach, ordinal: 1), content: "{\"kind\":\"no_card\"}")
        try await runtimeWait { (try? fixture.app.history().first { $0.id == second }?.coach?.status) == .succeeded }
        #expect(fixture.delivery.document.string == "I go A.I go B.")
        #expect(try fixture.app.history().first { $0.id == first }?.disposition == .completed)
    }

    @Test
    func retryAfterFromCoachHoldsAllUnsentRolesOnItsServiceWhileAnUnrelatedCoachServiceRemainsAvailable() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, concurrency: 1)
        defer { fixture.remove() }
        _ = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go A."])
        let failedCoach = try await fixture.request(.coach)
        let second = try await fixture.record()
        let asrB = try await fixture.request(.asr, ordinal: 1)
        let third = try await fixture.record()
        fixture.server.reply(failedCoach, object: ["error": ["message": "private coach body"]], status: 503, headers: ["Retry-After": "120"])
        try await runtimeWait { fixture.app.coachScheduler?.inFlightCount == 0 }
        fixture.server.reply(asrB, object: ["text": "I go B."])
        try await runtimeWait { (try? fixture.app.history().first { $0.id == second }?.coach?.status) == .waitingForBackoff && (try? fixture.app.history().first { $0.id == third }?.transcription?.status) == .waitingForBackoff }
        #expect(fixture.delivery.document.string == "I go A.I go B.")
        let another = ModelService(id: UUID(), name: "独立服务", baseURL: fixture.server.baseURL + "/other", authentication: .none)
        try fixture.services.saveService(another, newKey: nil, credentials: fixture.credentials)
        try fixture.coachSettings.save(.init(enabled: true, role: .init(serviceID: another.id, model: "runtime-coach-other")))
        fixture.app.configurationChanged()
        let other = try await fixture.request(.coach, raw: "I go B.")
        #expect(other.path == "/other/chat/completions")
        #expect(fixture.server.requests.filter { $0.role == .asr }.count == 2)
        fixture.server.replyChat(other, content: "{\"kind\":\"no_card\"}")
        try await runtimeWait { (try? fixture.app.history().first { $0.id == second }?.coach?.status) == .succeeded }
        #expect(fixture.server.requests.filter { $0.role == .coach && $0.userText == "I go A." }.count == 1)
    }

    @Test
    func theEncryptedPendingAudioBudgetStopsAtItsActualAllocatedBytesAndRetainsTheSafePCM() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.network.setAvailable(false)
        try fixture.resources.save(.init(maximumPendingAudioBytes: 64 * 1_024 * 1_024))
        #expect(await fixture.app.startRecording())
        let chunk = PCMChunk(samples: Data(repeating: 17, count: 1_048_576), sampleRate: 192_000)
        for _ in 0..<64 { fixture.source.emit(chunk) }
        await fixture.app.finishRecording()
        let entry = try #require(fixture.app.history().first)
        let usage = try fixture.app.queueUsage()
        #expect(usage.audioBytes <= 67_108_864)
        #expect(usage.audioBytes > 66_060_288)
        #expect(entry.frameCount > 0 && entry.frameCount < 33_554_432)
        #expect(fixture.app.notice == DictationError.pendingAudioLimit.localizedDescription)
        #expect(await fixture.app.startRecording() == false)
        #expect(try fixture.app.history().count == 1)
    }

    @Test(arguments: [CoachInputMode.text, .originalAudio])
    func bothCoachInputModesApplyTheSameUnsentNetworkGateBeforeReadingOriginalAudio(_ mode: CoachInputMode) async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        let id = try await fixture.record()
        fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."])
        try await runtimeWait { fixture.delivery.document.string == "I go yesterday." }
        try fixture.coachSettings.save(.init(enabled: true, role: .init(serviceID: fixture.serviceID, model: "runtime-coach"), inputMode: mode))
        let store = EncryptedHistory(directory: fixture.history, keys: TestDataKey())
        fixture.network.setAvailable(false)
        let gate = DispatchBackoff(network: fixture.network, timing: fixture.timing, now: { fixture.clock.date })
        var audioReads = 0
        let scheduler = try CoachWorkScheduler(settings: fixture.coachSettings, services: fixture.services, credentials: fixture.credentials, timing: fixture.timing,
            audioForSegment: { segment in audioReads += 1; return try store.waveAudio(segment) }, onUpdate: { update in try store.updateEntry(id) { $0.coach = update } })
        defer { scheduler.stopProcessing(); gate.stopWakeups() }
        scheduler.dispatchGate = { try gate.require($0) }
        gate.onReady = { try! scheduler.configurationChanged() }
        #expect(try scheduler.enqueue(segmentID: id, rawText: "I go yesterday."))
        fixture.timing.advance(to: 600)
        #expect(audioReads == 0 && scheduler.inFlightCount == 0)
        #expect(try store.entry(id).coach?.status == .waitingForNetwork)
        fixture.network.setAvailable(true)
        let coach = try await fixture.request(.coach)
        let object = try #require(try JSONSerialization.jsonObject(with: coach.body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let actualAudio = messages.contains { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "input_audio" } == true }
        #expect(actualAudio == (mode == .originalAudio))
        #expect(audioReads == (mode == .originalAudio ? 1 : 0))
        fixture.server.replyChat(coach, content: "{\"kind\":\"no_card\"}")
        try await runtimeWait { (try? store.entry(id).coach?.status) == .succeeded }
        #expect(try store.entry(id).coach?.dispatch?.audioUsed == actualAudio)
    }

    @Test(arguments: [DeliveryMode.recordingTarget, .currentCursor])
    func generatedAudioAndTheActualCrossAppAdapterDeliverAtTheFIFOHeadUsingTheSavedMode(_ mode: DeliveryMode) async throws {
        let environment = RuntimeInputEnvironment()
        let settingsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-delivery-mode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: settingsRoot) }
        let settings = DeliverySettings(file: settingsRoot.appendingPathComponent("delivery.json"))
        try settings.save(.init(mode: mode))
        let adapter = CrossAppTextDelivery(environment: environment, configuration: try settings.load())
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false, targetDelivery: adapter)
        defer { fixture.remove() }
        let first = try await fixture.record()
        let asrA = try await fixture.request(.asr)
        let second = try await fixture.record()
        let asrB = try await fixture.request(.asr, ordinal: 1)
        fixture.server.reply(asrB, object: ["text": "B."])
        try await runtimeWait { (try? fixture.app.rawTranscription(second)) == "B." }
        #expect(environment.first.document.string.isEmpty && environment.second.document.string.isEmpty)
        try settings.save(.init(mode: mode == .currentCursor ? .recordingTarget : .currentCursor))
        adapter.updateConfiguration(try settings.load())
        environment.focusSecond()
        fixture.server.reply(asrA, object: ["text": "A."])
        if mode == .currentCursor {
            try await runtimeWait { environment.second.document.string == "A.B." }
            #expect(try fixture.app.queue().isEmpty)
        } else {
            try await runtimeWait { (try? fixture.app.queue().first?.stage) == .awaitingManualDelivery }
            #expect(environment.second.document.string.isEmpty)
            try fixture.app.copyCurrentText(first)
            #expect(try fixture.app.queue().first?.id == first)
            #expect(throws: DictationError.outOfOrderDelivery) { try fixture.app.insertCurrentTextAtCurrentCursor(second) }
            #expect(try fixture.app.insertCurrentTextAtCurrentCursor(first) == .delivered)
            #expect(environment.second.document.string == "A.")
            #expect(try fixture.app.insertCurrentTextAtCurrentCursor(second) == .delivered)
            #expect(environment.second.document.string == "A.B.")
        }
        #expect(environment.first.document.string.isEmpty)
        #expect(environment.copied == (mode == .recordingTarget ? "A." : "等待时用户新复制的内容"))
    }

    @Test
    func reducingBothRequestBudgetsKeepsInFlightRequestsAndLimitsOnlyNewDispatch() async throws {
        let fixture = try RuntimeFixture(polishEnabled: false)
        defer { fixture.remove() }
        var ids: [UUID] = []
        for _ in 0..<5 { ids.append(try await fixture.record()) }
        var asrs: [RuntimeLoopbackServer.Request] = []
        for index in 0..<3 { asrs.append(try await fixture.request(.asr, ordinal: index)) }
        try fixture.app.updateProcessingConfiguration(.init(maximumConcurrentMainRequests: 1))
        #expect(fixture.app.mainRequestBudget.activeCount == 3)
        var coaches: [RuntimeLoopbackServer.Request] = []
        for (index, request) in asrs.enumerated() {
            fixture.server.reply(request, object: ["text": "I go \(index)."])
            coaches.append(try await fixture.request(.coach, raw: "I go \(index)."))
            if index < 2 { #expect(fixture.server.requests.filter { $0.role == .asr }.count == 3) }
        }
        let fourth = try await fixture.request(.asr, ordinal: 3)
        #expect(fixture.app.coachScheduler?.inFlightCount == 3)
        var config = try fixture.coachSettings.load(); config.concurrency = 1
        try fixture.coachSettings.save(config)
        fixture.server.reply(fourth, object: ["text": "I go 3."])
        _ = try await fixture.request(.asr, ordinal: 4)
        for (index, request) in coaches.enumerated() {
            fixture.server.replyChat(request, content: "{\"kind\":\"no_card\"}")
            try await runtimeWait { fixture.app.coachScheduler?.inFlightCount == (index == 2 ? 1 : 2 - index) }
            if index < 2 { #expect(fixture.server.requests.filter { $0.role == .coach }.count == 3) }
        }
        let newCoach = try await fixture.request(.coach, raw: "I go 3.")
        #expect(fixture.server.requests.filter { $0.role == .coach }.count == 4)
        #expect(fixture.app.coachScheduler?.configuration.concurrency == 1)
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        #expect(!fixture.server.disconnected(newCoach))
        #expect(try fixture.app.history().contains { $0.id == ids[4] })
    }

    @Test(arguments: [false, true])
    func offlineDefaultSendingWindowIsValidAt24HoursAndStickyImmediatelyAfterIt(_ expired: Bool) async throws {
        let fixture = try RuntimeFixture(polishEnabled: false, coachEnabled: false)
        defer { fixture.remove() }
        fixture.network.setAvailable(false)
        let id = try await fixture.record()
        let before = try #require(fixture.app.history().first)
        fixture.clock.date.addTimeInterval(expired ? 86_400.001 : 86_400)
        fixture.app.checkRecordingConditions()
        fixture.network.setAvailable(true)
        if expired {
            #expect(fixture.app.mainRequestBudget.activeCount == 0)
            #expect(try fixture.app.history().first?.queueStage == .waitingForResume)
            try fixture.resources.save(.init(automaticSendingWindow: 604_800))
            fixture.app.configurationChanged()
            #expect(fixture.app.mainRequestBudget.activeCount == 0)
            try fixture.app.resumePendingProcessing(id)
        }
        let sent = try await fixture.request(.asr)
        fixture.server.reply(sent, object: ["text": "At the explicit window."])
        try await runtimeWait { fixture.delivery.document.string == "At the explicit window." }
        let after = try #require(fixture.app.history().first)
        #expect(after.recordedAt == before.recordedAt && after.recordingEndedAt == before.recordingEndedAt)
        #expect(fixture.server.requests.count == 1)
    }

    @Test(arguments: [RuntimePreflightRole.asr, .polish, .coach])
    func aNetworkChangeDuringResultReservationStillPreventsTheActualRequest(_ role: RuntimePreflightRole) async throws {
        let fixture = try RuntimeFixture(polishEnabled: role == .polish, coachEnabled: role == .coach)
        defer { fixture.remove() }
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        var flipped = false
        fixture.capacity.onCheck = {
            guard !flipped, fixture.app.state == .ready else { return }
            let entry = try? fixture.app.history().first
            let matches = role == .asr ? entry?.rawTranscription == nil
                : role == .polish ? entry?.rawTranscription != nil && fixture.app.mainRequestBudget.activeCount == 2
                : entry?.coach?.status == .queued
            guard matches else { return }
            flipped = true
            fixture.network.setAvailable(false)
        }
        await fixture.app.finishRecording()
        if role != .asr { fixture.server.reply(try await fixture.request(.asr), object: ["text": "I go yesterday."]) }
        try await runtimeWait { flipped }
        fixture.capacity.onCheck = nil
        let entry = try #require(fixture.app.history().first)
        switch role {
        case .asr:
            #expect(entry.transcription?.status == .waitingForNetwork)
            #expect(fixture.app.mainRequestBudget.activeCount == 0)
        case .polish:
            #expect(entry.polish?.status == .waitingForNetwork)
            #expect(fixture.app.mainRequestBudget.activeCount == 0)
        case .coach:
            #expect(entry.coach?.status == .waitingForNetwork)
            #expect(fixture.app.coachScheduler?.inFlightCount == 0)
        }
        #expect(try fixture.app.reservedStorageBytes == 0)
        fixture.network.setAvailable(true)
        if role == .asr {
            fixture.server.reply(try await fixture.request(.asr), object: ["text": "Fresh online result."])
            try await runtimeWait { fixture.delivery.document.string == "Fresh online result." }
        } else if role == .polish {
            fixture.server.replyChat(try await fixture.request(.polish), content: "Fresh online polish.")
            try await runtimeWait { fixture.delivery.document.string == "Fresh online polish." }
        } else {
            fixture.server.replyChat(try await fixture.request(.coach), content: "{\"kind\":\"no_card\"}")
            try await runtimeWait { (try? fixture.app.history().first?.coach?.status) == .succeeded }
        }
    }

}

enum RuntimePreflightRole: Sendable { case asr, polish, coach }

enum RuntimeInvalidation: Sendable {
    case prepare, cancel, stop
    @MainActor func apply(to app: RecordingApplication, id: UUID) throws {
        switch self {
        case .prepare: app.prepareForTermination()
        case .cancel: try app.cancelRecordedSegment(id)
        case .stop: app.stopProcessing()
        }
    }
}

@MainActor
private final class RuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-runtime-\(UUID())")
    let source = RuntimeMicrophone()
    let server: RuntimeLoopbackServer
    let credentials = TestServiceCredentials()
    let services: ServiceSettings
    let polishSettings: PolishSettings
    let coachSettings: CoachSettings
    let resources: ResourceSettings
    let timing = ControlledRequestTiming()
    let clock = RuntimeClock()
    let capacity = RuntimeCapacity()
    let delivery = RuntimeDocumentDelivery()
    let network = RuntimeNetwork()
    let serviceID = UUID()
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }

    init(polishEnabled: Bool = true, coachEnabled: Bool = true, concurrency: Int = 3, targetDelivery: (any TextDelivering)? = nil) throws {
        server = try RuntimeLoopbackServer()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        polishSettings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        coachSettings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        resources = ResourceSettings(file: root.appendingPathComponent("resources.json"))
        let service = ModelService(id: serviceID, name: "合成口述 loopback", baseURL: server.baseURL, authentication: .bearerToken)
        try services.save(ModelConfiguration(services: [service], transcription: .init(serviceID: serviceID, model: "runtime-asr")))
        try credentials.saveKey("runtime-fake-key", for: serviceID)
        try polishSettings.save(PolishConfiguration(enabled: polishEnabled, role: .init(serviceID: serviceID, model: "runtime-polish"), customPrompt: "完整润色提示词，仅整理本段。"))
        try coachSettings.save(CoachConfiguration(enabled: coachEnabled, role: .init(serviceID: serviceID, model: "runtime-coach"), customPrompt: "完整文本带教提示词，不评流利度。"))
        let clock = self.clock, capacity = self.capacity
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            now: { clock.date },
            diskSpace: { _ in capacity.onCheck?(); return capacity.bytes },
            transcription: TranscriptionDependencies(settings: services, credentials: credentials, delivery: targetDelivery ?? delivery, timing: timing),
            polish: PolishClient(settings: polishSettings, services: services, credentials: credentials, timing: timing),
            coach: CoachDependencies(settings: coachSettings, services: services, credentials: credentials, timing: timing),
            resourceSettings: resources, network: network)
        try app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency))
    }

    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw RuntimeTestError.recording }
        source.emit(testAudio())
        await app.finishRecording()
        return id
    }

    func request(_ role: RuntimeRole, raw: String? = nil, ordinal: Int = 0) async throws -> RuntimeLoopbackServer.Request {
        try await runtimeWait { self.server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }.count > ordinal }
        return server.requests.filter { $0.role == role && (raw == nil || $0.userText == raw) }[ordinal]
    }

    func remove() {
        capacity.onCheck = nil; app.onChange = nil
        app.stopProcessing(); source.stop(); timing.cancelAll(); server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class RuntimeClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
private final class RuntimeCapacity {
    var bytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
    var onCheck: (() -> Void)?
}

@MainActor
private final class RuntimeMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> { AsyncThrowingStream { stream = $0 } }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}

@MainActor
private final class RuntimeDocumentDelivery: TextDelivering {
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

private enum RuntimeRole { case asr, polish, coach }

private final class RuntimeLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let path: String
        let authorization: String?
        let body: Data
        private var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var role: RuntimeRole { path.hasSuffix("audio/transcriptions") ? .asr : model.contains("coach") ? .coach : .polish }
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
        guard descriptor >= 0 else { throw RuntimeTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(descriptor, 32) == 0 else { close(descriptor); throw RuntimeTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(descriptor); throw RuntimeTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "model-runtime-loopback").async { [self] in
            defer { close(descriptor) }
            while !lock.withLock({ stopped }) {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }

    func reply(_ request: Request, object: [String: Any], status: Int = 200, headers: [String: String] = [:]) {
        reply(request, body: try! JSONSerialization.data(withJSONObject: object), status: status, headers: headers)
    }
    func replyChat(_ request: Request, content: String, status: Int = 200) {
        reply(request, object: ["choices": [["message": ["content": content]]]], status: status)
    }
    func reply(_ request: Request, body: Data, status: Int = 200, headers: [String: String] = [:]) {
        let extraHeaders = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        let header = Data("HTTP/1.1 \(status) Controlled\r\n\(extraHeaders)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
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

private func runtimeCard(original: String, improved: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["kind": "card", "suggestions": [["category": "grammar", "original": original, "improved": improved, "reason": "昨天发生的动作应使用过去式。"]]]), encoding: .utf8)!
}

@MainActor
private func runtimeWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw RuntimeTestError.wait }
        await Task.yield()
    }
}

private enum RuntimeTestError: Error { case socket, recording, wait }

@MainActor
private final class RuntimeNetwork: NetworkAvailabilityProviding {
    var onChange: (() -> Void)?
    private var available = true
    func isAvailable(for url: URL) -> Bool { available }
    func setAvailable(_ value: Bool) { available = value; onChange?() }
}

@MainActor
private final class RuntimeInputEnvironment: CrossAppTextEnvironment {
    var accessibilityAuthorized = true
    var secureInputActive = false
    var instant: TimeInterval = 10
    let first = RuntimeNativeDocumentInput(), second = RuntimeNativeDocumentInput()
    var copied = "等待时用户新复制的内容"
    private var focusedSecond = false
    private var inputHandler: (() -> Void)?
    func focusedInput() -> (any CrossAppTextInput)? { focusedSecond ? second : first }
    func focusSecond() { focusedSecond = true; first.emit(.focusChanged); second.emit(.focusChanged) }
    func monitorUserInput(_ handler: @escaping @MainActor () -> Void) -> Bool { inputHandler = handler; return true }
    func stopMonitoringUserInput() { inputHandler = nil }
    func copy(_ text: String) { copied = text }
}

@MainActor
private final class RuntimeNativeDocumentInput: CrossAppTextInput {
    let document = NSTextView()
    private var handlers: [UUID: (CrossAppInputEvent) -> Void] = [:]
    func isSameInput(as other: any CrossAppTextInput) -> Bool { (other as? RuntimeNativeDocumentInput) === self }
    func readSnapshot() -> CrossAppInputSnapshot? { CrossAppInputSnapshot(text: document.string, selection: document.selectedRange()) }
    func observe(_ handler: @escaping @MainActor (CrossAppInputEvent) -> Void) -> (any CrossAppInputObservation)? {
        let id = UUID(); handlers[id] = handler
        return RuntimeInputObservation { [weak self] in self?.handlers[id] = nil }
    }
    func insertSelectedText(_ text: String) -> Bool {
        document.insertText(text, replacementRange: document.selectedRange())
        emit(.valueChanged); emit(.selectionChanged)
        return true
    }
    func emit(_ event: CrossAppInputEvent) { for handler in Array(handlers.values) { handler(event) } }
}

@MainActor
private final class RuntimeInputObservation: CrossAppInputObservation {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func stop() { action?(); action = nil }
}
