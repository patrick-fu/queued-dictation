import AppKit
import AVFAudio
import CryptoKit
import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct QueueBehaviorTests {
    @Test
    func threeResponsesOutOfOrderReachTheDocumentInRecordingStartOrder() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        try await waitUntil { if case .recording(_, let duration) = fixture.app.state { return duration == 0.5 }; return false }
        #expect(try fixture.app.queue().last?.stage == .recording)
        await fixture.app.finishRecording()
        let second = try #require(fixture.app.history().first { $0.id != first })
        let third = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 3 }
        fixture.server.reply(index: 2, text: "丙。")
        try await waitUntil { (try? fixture.app.rawTranscription(third)) == "丙。" }
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.rawTranscription(second.id)) == "乙。" }
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(try fixture.app.queue().map(\.id) == [first, second.id, third])
        #expect(try fixture.app.queue().map(\.stage) == [.transcribing, .waitingForPredecessor, .waitingForPredecessor])
        fixture.server.reply(index: 0, text: "甲。")
        try await waitUntil { fixture.delivery.document.string == "甲。乙。丙。" }
        #expect(try fixture.app.history().allSatisfy { $0.disposition == .completed })
        for id in [first, second.id, third] {
            let output = fixture.root.appendingPathComponent("\(id).wav")
            try fixture.app.exportAudio(id, to: output)
            #expect(try AVAudioFile(forReading: output).length == 4_000)
        }
        let data = try savedFiles(fixture.history)
        #expect(data.values.allSatisfy { $0.starts(with: Data("QDENC1".utf8)) })
        #expect(data.values.allSatisfy { $0.range(of: Data("丙。".utf8)) == nil })
    }

    @Test
    func allowedPendingAudioKeepsEveryFrameFromTheBoundedCaptureStream() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let templateID = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        fixture.server.reply(index: 0, text: "模板已交付。")
        try await waitUntil { fixture.delivery.document.string == "模板已交付。" }
        fixture.app.stopProcessing()
        let template = try Data(contentsOf: fixture.history.appendingPathComponent("history/\(templateID)/entry.enc"))
        let vault = fixture.history
        try await Task.detached { try seedEncryptedPendingAudio(template, templateID: templateID, vault: vault) }.value
        let source = BoundedQueueMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: fixture.history, keys: TestDataKey(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            transcription: TranscriptionDependencies(settings: fixture.settings, credentials: fixture.credentials,
                delivery: fixture.delivery, timing: fixture.timing))
        defer { source.stop(); app.stopProcessing() }
        let before = try app.queueUsage()
        #expect(before.segments == 2)
        #expect(before.duration < 30 * 60)
        #expect(before.audioBytes < 256 * 1_024 * 1_024)
        let began = ContinuousClock.now
        #expect(await app.startRecording())
        let deadline = ContinuousClock.now + .seconds(45)
        while app.state != .ready {
            guard ContinuousClock.now < deadline else { throw TestWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        let latest = try #require(app.history().first { $0.recordingOrder == 4 })
        print("BOUNDED_QUEUE_CAPTURE pending=\(before) frames=\(latest.frameCount)/491520 notice=\(String(describing: app.notice)) elapsed=\(began.duration(to: .now))")
        #expect(latest.frameCount == 491_520)
        let output = fixture.root.appendingPathComponent("bounded-capture.wav")
        try app.exportAudio(latest.id, to: output)
        #expect(try AVAudioFile(forReading: output).length == 491_520)
        #expect(try Data(contentsOf: output).dropFirst(44) == Data(repeating: 0x52, count: 983_040))
        let savedChunk = try Data(contentsOf: fixture.history.appendingPathComponent("history/\(latest.id)/00000000.audio"))
        #expect(savedChunk.starts(with: Data("QDENC1".utf8)))
        let decodedChunk = try AES.GCM.open(AES.GCM.SealedBox(combined: savedChunk.dropFirst(6)),
            using: SymmetricKey(data: TestDataKey().bytes), authenticating: Data("\(latest.id)/audio/0".utf8))
        #expect(decodedChunk == Data(repeating: 0x52, count: 8_192))
    }

    @Test
    func cachedFootprintsTrackActiveGrowthAndCancellationWhileTerminalHistoryKeepsItsLocalOccupancy() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        let firstBytes = try actualAudioFootprint(fixture.history)
        #expect(try fixture.app.queueUsage().audioBytes == firstBytes)
        #expect(await fixture.app.startRecording())
        guard case .recording(let second, _) = fixture.app.state else { throw QueueTestError.recording }
        #expect(try fixture.app.queueUsage().audioBytes == firstBytes)
        fixture.source.emit(testAudio())
        try await waitUntil { if case .recording(_, let duration) = fixture.app.state { return duration == 0.5 }; return false }
        #expect(try fixture.app.queueUsage().audioBytes == actualAudioFootprint(fixture.history))
        fixture.source.emit(testAudio())
        try await waitUntil { if case .recording(_, let duration) = fixture.app.state { return duration == 1 }; return false }
        let grownBytes = try actualAudioFootprint(fixture.history)
        #expect(grownBytes > firstBytes)
        #expect(try fixture.app.queueUsage().audioBytes == grownBytes)
        await fixture.app.finishRecording()
        #expect(try fixture.app.queueUsage().audioBytes == grownBytes)
        let retained = try savedFiles(fixture.history).filter { $0.key.hasSuffix(".audio") && $0.key.contains(second.uuidString) }
        try fixture.app.cancelRecordedSegment(second)
        #expect(try fixture.app.queueUsage().audioBytes == firstBytes)
        #expect(try savedFiles(fixture.history).filter { $0.key.hasSuffix(".audio") && $0.key.contains(second.uuidString) } == retained)
        try fixture.app.deleteHistory(first)
        #expect(try fixture.app.queueUsage().segments == 0)
        #expect(try fixture.app.queueUsage().duration == 0)
        #expect(try fixture.app.queueUsage().audioBytes == 0)
        #expect(try actualAudioFootprint(fixture.history) == grownBytes - firstBytes)
        let occupied = try actualLocalFootprint(fixture.history)
        let limited = RecordingApplication(source: ControlledMicrophone(), historyDirectory: fixture.history, keys: TestDataKey(),
            limits: RecordingLimits(maximumLocalBytes: occupied + 1_048_576 + 32_767), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        #expect(await limited.startRecording() == false)
        #expect(limited.notice?.contains("本地数据") == true)
        let output = fixture.root.appendingPathComponent("retained-terminal.wav")
        try fixture.app.exportAudio(second, to: output)
        #expect(try AVAudioFile(forReading: output).length == 8_000)
    }

    @Test
    func discardingActiveAudioRemovesOnlyItsOccupancyAndTheNextRecordingUsesFreshAllocation() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        let firstBytes = try fixture.app.queueUsage().audioBytes
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        try await waitUntil { if case .recording(_, let duration) = fixture.app.state { return duration == 0.5 }; return false }
        #expect(try fixture.app.queueUsage().audioBytes > firstBytes)
        await fixture.app.cancelCurrentRecording()
        #expect(try fixture.app.queueUsage().audioBytes == firstBytes)
        #expect(try actualAudioFootprint(fixture.history) == firstBytes)
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        let next = try await fixture.record()
        #expect(try fixture.app.history().count == 2)
        #expect(try fixture.app.history().contains { $0.id == first })
        #expect(try fixture.app.history().contains { $0.id == next })
        #expect(try fixture.app.queueUsage().audioBytes == actualAudioFootprint(fixture.history))
    }

    @Test
    func failedDeletionKeepsAudioQuotaAccurateAndRecordingStillStopsAtTheRealAllocationLimit() async throws {
        let fixture = try QueueFixture(queueLimits: QueueLimits(maximumPendingAudioBytes: 12_288))
        defer { fixture.remove() }
        let first = try await fixture.record()
        let before = try fixture.app.queueUsage().audioBytes
        let directory = fixture.history.appendingPathComponent("history/\(first)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        var deletionFailed = false
        do { try fixture.app.deleteHistory(first) }
        catch { deletionFailed = true }
        #expect(deletionFailed)
        #expect(try fixture.app.queueUsage().audioBytes == before)
        #expect(try fixture.app.queueUsage().audioBytes == actualAudioFootprint(fixture.history))
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        try await waitUntil { fixture.app.state == .ready }
        let second = try #require(fixture.app.history().first { $0.id != first })
        #expect(second.frameCount > 0 && second.frameCount < 4_000)
        #expect(try actualAudioFootprint(fixture.history) <= 12_288)
        #expect(try fixture.app.queueUsage().audioBytes == actualAudioFootprint(fixture.history))
    }

    @Test(arguments: [true, false])
    func preparingForTerminationBlocksAuthorizationAlreadyQueuedOrGrantedAfterPreparation(_ grantQueuedFirst: Bool) async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        fixture.source.authorization = .notDetermined
        fixture.source.holdAuthorization = true
        fixture.source.audioOnStart = testAudio()
        let starting = Task { await fixture.app.startRecording() }
        try await waitUntil { fixture.app.state == .requestingMicrophone }
        if grantQueuedFirst { fixture.source.completeAuthorization(.authorized) }
        fixture.app.prepareForTermination()
        if !grantQueuedFirst { fixture.source.completeAuthorization(.authorized) }
        #expect(await starting.value == false)
        await fixture.app.finishRecording()
        #expect(fixture.source.startCount == 0)
        #expect(try fixture.app.history().isEmpty)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.app.state == .ready)
        #expect(await fixture.app.startRecording() == false)
        await fixture.app.finishRecording()
    }

    @Test
    func preparingForTerminationPreservesTheReliableRecordingPrefixWithoutDispatchingANewRequest() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        fixture.app.onChange = { [weak fixture] in
            guard let fixture else { return }
            if (try? fixture.app.history().contains { $0.transcription?.status == .inFlight }) == true { usleep(50_000) }
        }
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        try await waitUntil { if case .recording(_, let duration) = fixture.app.state { return duration == 0.5 }; return false }
        fixture.app.prepareForTermination()
        fixture.app.prepareForTermination()
        fixture.app.configurationChanged()
        await fixture.app.finishRecording()
        let entry = try #require(fixture.app.history().first)
        #expect(entry.frameCount == 4_000)
        #expect(entry.disposition == .awaitingProcessing)
        #expect(entry.transcription?.status == .waitingForSlot)
        #expect(entry.transcription?.attemptID == nil)
        #expect(try fixture.app.queue().first?.stage == .interrupted)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        let download = fixture.root.appendingPathComponent("termination-prefix.wav")
        try fixture.app.exportAudio(entry.id, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
        #expect(try Data(contentsOf: download).suffix(testAudio().samples.count) == testAudio().samples)
        #expect(throws: DictationError.applicationTerminating) { try fixture.app.retryTranscription(entry.id) }
        #expect(await fixture.app.startRecording() == false)
        #expect(fixture.source.startCount == 1)
        await fixture.app.finishRecording()
    }

    @Test
    func preparingForTerminationInvalidatesAQueuedModelCompletionAndKeepsUnsentAudioForExplicitRecovery() async throws {
        let fixture = try QueueFixture(concurrency: 1)
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        fixture.server.reply(index: 0, text: "退出后不应复活的旧结果。")
        // 模拟窗口渲染暂占主线程，让真实 HTTP 的完成消息排在同步退出准备之后执行。
        usleep(50_000)
        fixture.app.prepareForTermination()
        fixture.app.configurationChanged()
        fixture.timing.advance(to: 60)
        await fixture.app.finishRecording()
        for _ in 0..<20 { await Task.yield() }
        let entries = try fixture.app.history()
        #expect(entries.first { $0.id == first }?.transcription?.status == .interrupted)
        #expect(entries.first { $0.id == first }?.rawTranscription == nil)
        #expect(entries.first { $0.id == second }?.transcription?.status == .waitingForSlot)
        #expect(entries.allSatisfy { $0.disposition == .awaitingProcessing })
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.app.mainRequestBudget.activeCount == 0)
        let download = fixture.root.appendingPathComponent("termination-unsent.wav")
        try fixture.app.exportAudio(second, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
    }

    @Test
    func stoppingProcessingWithoutTerminationStillAllowsAnotherRecordingAndRequest() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        fixture.app.stopProcessing()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(index: 1, text: "停止处理后仍可录音。")
        try await waitUntil { (try? fixture.app.rawTranscription(second)) == "停止处理后仍可录音。" }
        try fixture.app.skipMainDelivery(first)
        #expect(fixture.delivery.document.string == "停止处理后仍可录音。")
        #expect(fixture.source.startCount == 2)
    }

    @Test
    func failedRetryPersistenceKeepsTheUnsavedStorageFailureUntilExplicitRetrySucceeds() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let id = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 1 }
        let entryDirectory = fixture.history.appendingPathComponent("history/\(id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: entryDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path) }
        fixture.server.reply(index: 0, text: "未能持久化的旧文本。")
        try await waitUntil { (try? fixture.app.history().first?.transcription?.failure) == .storageFailure }
        var writeError: NSError?
        do { try fixture.app.retryTranscription(id) }
        catch { writeError = error as NSError }
        #expect(writeError?.domain == NSCocoaErrorDomain)
        #expect(writeError?.code == NSFileWriteNoPermissionError)
        #expect(try fixture.app.history().first?.transcription?.status == .failed)
        #expect(try fixture.app.history().first?.transcription?.failure == .storageFailure)
        #expect(try fixture.app.queue().first?.stage == .failed)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.server.requests.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path)
        fixture.app.configurationChanged()
        #expect(try fixture.app.history().first?.transcription?.failure == .storageFailure)
        #expect(fixture.server.requests.count == 1)
        try fixture.app.retryTranscription(id)
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(index: 1, text: "显式重试后成功。")
        try await waitUntil { fixture.delivery.document.string == "显式重试后成功。" }
        let download = fixture.root.appendingPathComponent("retained-after-failed-retry.wav")
        try fixture.app.exportAudio(id, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
    }

    @Test
    func aFailedHeadHoldsAReadyFollowerUntilExplicitRetrySucceeds() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(index: 0, text: "服务错误正文不展示", status: 401)
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.queue().first?.stage) == .failed && (try? fixture.app.rawTranscription(second)) == "乙。" }
        fixture.app.configurationChanged()
        #expect(fixture.server.requests.count == 2)
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(try fixture.app.queue().first?.reason?.contains("凭据") == true)
        let oldAttempt = try fixture.app.history().first { $0.id == first }?.transcription?.attemptID
        try fixture.app.retryTranscription(first)
        try await waitUntil { fixture.server.requests.count == 3 }
        #expect(try fixture.app.history().first { $0.id == first }?.transcription?.attemptID != oldAttempt)
        fixture.server.reply(index: 2, text: "甲。")
        try await waitUntil { fixture.delivery.document.string == "甲。乙。" }
        #expect(try fixture.app.queue().isEmpty)
    }

    @Test
    func copyingDoesNotReleaseAManualHeadAndOnlyTheHeadCanBeInserted() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.delivery.result = .manual
        fixture.server.reply(index: 0, text: "甲。")
        try await waitUntil { (try? fixture.app.queue().first?.stage) == .awaitingManualDelivery }
        fixture.delivery.result = .delivered
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.rawTranscription(second)) == "乙。" }
        try fixture.app.copyRawTranscription(first)
        #expect(fixture.delivery.copied == "甲。")
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(try fixture.app.queue().count == 2)
        #expect(throws: DictationError.outOfOrderDelivery) { try fixture.app.insertRawTranscriptionAtCurrentCursor(second) }
        #expect(try fixture.app.insertRawTranscriptionAtCurrentCursor(first) == .delivered)
        #expect(fixture.delivery.document.string == "甲。乙。")
        #expect(try fixture.app.queue().isEmpty)
    }

    @Test
    func uncertainDeliveryBlocksFollowersAndConfirmationDoesNotWriteTheHeadTwice() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.delivery.result = .uncertain
        fixture.server.reply(index: 0, text: "甲。")
        try await waitUntil { (try? fixture.app.queue().first?.stage) == .deliveryUncertain }
        fixture.delivery.result = .delivered
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.rawTranscription(second)) == "乙。" }
        #expect(fixture.delivery.document.string == "甲。")
        #expect(fixture.delivery.copied == "用户等待时复制的新内容")
        try fixture.app.copyRawTranscription(first)
        #expect(try fixture.app.queue().count == 2)
        #expect(throws: DictationError.deliveryUncertain) { try fixture.app.insertRawTranscriptionAtCurrentCursor(first) }
        #expect(throws: DictationError.outOfOrderDelivery) { try fixture.app.confirmManuallyDelivered(second) }
        try fixture.app.confirmManuallyDelivered(first)
        // A 的实际写回未得到确认，因此 B 的旧快照也不能假定有效。
        #expect(fixture.delivery.document.string == "甲。")
        #expect(try fixture.app.queue().first?.stage == .awaitingManualDelivery)
        #expect(try fixture.app.insertRawTranscriptionAtCurrentCursor(second) == .delivered)
        #expect(fixture.delivery.document.string == "甲。乙。")
    }

    @Test
    func loweringConcurrencyKeepsSentRequestsAndQueuedDispatchUsesTheLatestConfiguration() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        _ = try await fixture.record()
        _ = try await fixture.record()
        let fourth = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 3 }
        #expect(try fixture.app.queue().last?.stage == .waitingForSlot)
        #expect(try fixture.app.history().first { $0.id == fourth }?.frameCount == 4_000)
        try fixture.app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: 1))
        let latest = ModelService(name: "最新本机服务", baseURL: fixture.server.baseURL + "/latest", authentication: .bearerToken)
        try fixture.settings.save(ModelConfiguration(services: [latest], transcription: ModelRoleConfiguration(serviceID: latest.id, model: "latest-asr")))
        try fixture.credentials.saveKey("local-fake-latest-key", for: latest.id)
        fixture.app.configurationChanged()
        #expect(fixture.app.mainRequestBudget.activeCount == 3)
        fixture.server.reply(index: 2, text: "丙。")
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.queue().filter { $0.hasText }.count) == 2 }
        #expect(fixture.server.requests.count == 3)
        #expect(fixture.app.mainRequestBudget.activeCount == 1)
        fixture.server.reply(index: 0, text: "甲。")
        try await waitUntil { fixture.server.requests.count == 4 }
        #expect(try fixture.app.history().first { $0.id == first }?.disposition == .completed)
        let request = try #require(fixture.server.requests.last)
        #expect(request.path == "/latest/audio/transcriptions")
        #expect(request.authorization == "Bearer local-fake-latest-key")
        #expect(request.body.range(of: Data("latest-asr".utf8)) != nil)
        #expect(request.body.range(of: Data("RIFF".utf8)) != nil)
        fixture.server.reply(index: 3, text: "丁。")
        try await waitUntil { fixture.delivery.document.string == "甲。乙。丙。丁。" }
        #expect(throws: ProcessingSettingsError.invalidConcurrency) { try fixture.app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: 0)) }
        #expect(throws: ProcessingSettingsError.invalidConcurrency) { try fixture.app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: 11)) }
        #expect(try fixture.app.processingConfiguration.maximumConcurrentMainRequests == 1)
    }

    @Test
    func aPolishLeaseAndTranscriptionUseOneBudgetWithoutBlockingRecording() async throws {
        let fixture = try QueueFixture(concurrency: 1)
        defer { fixture.remove() }
        let slot = try #require(fixture.app.mainRequestBudget.acquire(for: .polish))
        let first = try await fixture.record()
        let second = try await fixture.record()
        #expect(fixture.server.requests.isEmpty)
        #expect(try fixture.app.queue().map(\.stage) == [.waitingForSlot, .waitingForSlot])
        #expect(try fixture.app.history().first { $0.id == second }?.frameCount == 4_000)
        fixture.app.mainRequestBudget.release(slot)
        try await waitUntil { fixture.server.requests.count == 1 }
        fixture.server.reply(index: 0, text: "甲。")
        try await waitUntil { fixture.server.requests.count == 2 }
        #expect(try fixture.app.history().first { $0.id == first }?.disposition == .completed)
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { fixture.delivery.document.string == "甲。乙。" }
    }

    @Test
    func recordedCancellationAndSkippingReleaseOrderWithoutDeletingAudioOrCancellingOtherRequests() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        let third = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 3 }
        fixture.server.reply(index: 1, text: "已取消的旧回调。")
        try fixture.app.cancelRecordedSegment(second)
        fixture.server.reply(index: 2, text: "丙。")
        try await waitUntil { (try? fixture.app.rawTranscription(third)) == "丙。" }
        #expect(try fixture.app.history().first { $0.id == second }?.rawTranscription == nil)
        #expect(try fixture.app.history().first { $0.id == second }?.disposition == .cancelled)
        #expect(try fixture.app.history().first { $0.id == first }?.transcription?.status == .inFlight)
        #expect(fixture.delivery.document.string.isEmpty)
        try fixture.app.skipMainDelivery(first)
        try await waitUntil { fixture.delivery.document.string == "丙。" }
        fixture.server.reply(index: 0, text: "跳过的旧回调。")
        #expect(try fixture.app.history().first { $0.id == first }?.delivery == .skipped)
        let download = fixture.root.appendingPathComponent("cancelled.wav")
        try fixture.app.exportAudio(second, to: download)
        #expect(try AVAudioFile(forReading: download).length == 4_000)
    }

    @Test
    func aTimedOutHeadBlocksReadyFollowersAndAnOldResultCannotReplaceItsRetry() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.rawTranscription(second)) == "乙。" }
        fixture.server.reply(index: 0, text: "旧结果。")
        fixture.timing.advance(to: 60)
        fixture.app.checkRecordingConditions()
        try await waitUntil { (try? fixture.app.queue().first?.stage) == .timedOut }
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(try fixture.app.history().first { $0.id == first }?.rawTranscription == nil)
        try fixture.app.retryTranscription(first)
        try await waitUntil { fixture.server.requests.count == 3 }
        fixture.server.reply(index: 2, text: "甲。")
        try await waitUntil { fixture.delivery.document.string == "甲。乙。" }
        #expect(try fixture.app.rawTranscription(first) == "甲。")
    }

    @Test
    func differentTargetsNeverReceiveEachOthersTextAndUserEditingStopsAutomaticDelivery() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        fixture.delivery.focusedOther = true
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(index: 1, text: "乙。")
        fixture.server.reply(index: 0, text: "甲。")
        try await waitUntil { (try? fixture.app.queue().first?.stage) == .awaitingManualDelivery }
        #expect(fixture.delivery.document.string.isEmpty)
        #expect(fixture.delivery.otherDocument.string.isEmpty)
        try fixture.app.skipMainDelivery(first)
        #expect(fixture.delivery.otherDocument.string == "乙。")
        #expect(fixture.delivery.document.string.isEmpty)
        let third = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 3 }
        fixture.delivery.otherDocument.insertText("用户手打。", replacementRange: fixture.delivery.otherDocument.selectedRange())
        fixture.server.reply(index: 2, text: "丙。")
        try await waitUntil { (try? fixture.app.queue().first?.id) == third && (try? fixture.app.queue().first?.stage) == .awaitingManualDelivery }
        #expect(fixture.delivery.otherDocument.string == "乙。用户手打。")
        #expect(try fixture.app.rawTranscription(second) == "乙。")
    }

    @Test
    func restartNeverResendsSavedWorkAndPreservesItsOrderAheadOfARecordingAfterTheClockMovesBack() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.record()
        let second = try await fixture.record()
        try await waitUntil { fixture.server.requests.count == 2 }
        fixture.server.reply(index: 1, text: "乙。")
        try await waitUntil { (try? fixture.app.rawTranscription(second)) == "乙。" }
        fixture.app.stopProcessing()
        let source = ControlledMicrophone()
        let delivery = QueueDocumentDelivery()
        let restarted = RecordingApplication(source: source, historyDirectory: fixture.history, keys: TestDataKey(),
            now: { Date(timeIntervalSince1970: 1_600_000_000) },
            transcription: TranscriptionDependencies(settings: fixture.settings, credentials: fixture.credentials, delivery: delivery, timing: fixture.timing))
        defer { restarted.stopProcessing() }
        restarted.configurationChanged()
        #expect(fixture.server.requests.count == 2)
        #expect(try restarted.queue().map(\.id) == [first, second])
        #expect(try restarted.queue().first?.stage == .interrupted)
        #expect(await restarted.startRecording())
        guard case .recording(let third, _) = restarted.state else { throw QueueTestError.recording }
        source.emit(testAudio())
        await restarted.finishRecording()
        try await waitUntil { fixture.server.requests.count == 3 }
        #expect(try restarted.queue().map(\.id) == [first, second, third])
        try restarted.skipMainDelivery(first)
        #expect(try restarted.queue().first?.stage == .awaitingManualDelivery)
        #expect(delivery.document.string.isEmpty)
        #expect(try restarted.insertRawTranscriptionAtCurrentCursor(second) == .delivered)
        fixture.server.reply(index: 2, text: "丙。")
        try await waitUntil { delivery.document.string == "乙。丙。" }
    }

    @Test(arguments: [1, 10])
    func theConfiguredRequestBoundsAllowRecordingBeyondTheNetworkCapacity(_ concurrency: Int) async throws {
        let fixture = try QueueFixture(concurrency: concurrency)
        defer { fixture.remove() }
        for _ in 0...concurrency { _ = try await fixture.record() }
        try await waitUntil { fixture.server.requests.count == concurrency }
        #expect(fixture.app.mainRequestBudget.activeCount == concurrency)
        #expect(try fixture.app.queue().last?.stage == .waitingForSlot)
        #expect(try fixture.app.history().count == concurrency + 1)
    }

    @Test
    func theDefaultPendingCountStopsAtTwentyAndCancellingARecordedSegmentAllowsTheNextRecording() async throws {
        let fixture = try QueueFixture()
        defer { fixture.remove() }
        var first: UUID?
        for _ in 0..<20 { let id = try await fixture.record(); if first == nil { first = id } }
        #expect(try fixture.app.queueUsage().segments == 20)
        #expect(await fixture.app.startRecording() == false)
        #expect(fixture.app.notice?.contains("片段数") == true)
        try fixture.app.cancelRecordedSegment(#require(first))
        #expect(await fixture.app.startRecording())
        #expect(try fixture.app.queueUsage().segments == 20)
        fixture.source.emit(testAudio())
        await fixture.app.cancelCurrentRecording()
        #expect(try fixture.app.history().count == 20)
    }

    @Test
    func pendingSegmentCapacityReservesTheActiveRecordingAndTerminalHistoryStillOccupiesLocalStorage() async throws {
        let fixture = try QueueFixture(queueLimits: QueueLimits(maximumPendingSegments: 2))
        defer { fixture.remove() }
        let first = try await fixture.record()
        #expect(await fixture.app.startRecording())
        #expect(try fixture.app.queueUsage().segments == 2)
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        #expect(await fixture.app.startRecording() == false)
        #expect(fixture.app.notice?.contains("片段数") == true)
        let savedAudio = try savedFiles(fixture.history).filter { $0.key.hasSuffix(".audio") }
        try fixture.app.skipMainDelivery(first)
        #expect(try fixture.app.queueUsage().segments == 1)
        #expect(try savedFiles(fixture.history).filter { $0.key.hasSuffix(".audio") } == savedAudio)
        #expect(await fixture.app.startRecording())
        await fixture.app.cancelCurrentRecording()
        #expect(try fixture.app.queueUsage().segments == 1)
    }

    @Test
    func reachingPendingDurationDuringRecordingKeepsOnlyTheAcceptedAudioAndRefusesAnotherSegment() async throws {
        let fixture = try QueueFixture(queueLimits: QueueLimits(maximumPendingDuration: 1.25))
        defer { fixture.remove() }
        let first = try await fixture.record()
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        fixture.source.emit(testAudio())
        try await waitUntil { fixture.app.state == .ready }
        #expect(try fixture.app.queueUsage().duration == 1.25)
        #expect(fixture.app.notice?.contains("累计音频时长") == true)
        let second = try #require(fixture.app.history().first { $0.id != first })
        let download = fixture.root.appendingPathComponent("limited.wav")
        try fixture.app.exportAudio(second.id, to: download)
        #expect(try AVAudioFile(forReading: download).length == 6_000)
        #expect(await fixture.app.startRecording() == false)
        try fixture.app.skipMainDelivery(first)
        #expect(await fixture.app.startRecording())
        await fixture.app.cancelCurrentRecording()
    }

    @Test
    func reachingPendingAudioBytesDuringRecordingKeepsPlayableAudio() async throws {
        let fixture = try QueueFixture(queueLimits: QueueLimits(maximumPendingAudioBytes: 12_288))
        defer { fixture.remove() }
        let first = try await fixture.record()
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        try await waitUntil { fixture.app.state == .ready }
        #expect(try fixture.app.queueUsage().audioBytes <= 12_288)
        #expect(fixture.app.notice?.contains("主积压音频") == true)
        let second = try #require(fixture.app.history().first { $0.id != first })
        #expect(second.frameCount > 0 && second.frameCount < 4_000)
        let download = fixture.root.appendingPathComponent("byte-limited.wav")
        try fixture.app.exportAudio(second.id, to: download)
        #expect(try AVAudioFile(forReading: download).length == Int64(second.frameCount))
        #expect(await fixture.app.startRecording() == false)
        try fixture.app.cancelRecordedSegment(first)
        #expect(await fixture.app.startRecording())
        await fixture.app.cancelCurrentRecording()
    }
}

@MainActor
private final class QueueFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = QueueMicrophone()
    let server: QueueLoopbackServer
    let delivery = QueueDocumentDelivery()
    let timing = ControlledRequestTiming()
    let credentials = TestServiceCredentials()
    let settings: ServiceSettings
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }
    init(queueLimits: QueueLimits = QueueLimits(), concurrency: Int? = nil) throws {
        server = try QueueLoopbackServer()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = ServiceSettings(file: root.appendingPathComponent("services.json"))
        let service = ModelService(name: "本机受控服务", baseURL: server.baseURL, authentication: .bearerToken)
        try settings.save(ModelConfiguration(services: [service], transcription: ModelRoleConfiguration(serviceID: service.id, model: "controlled-asr")))
        try credentials.saveKey("local-fake-queue-key", for: service.id)
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            transcription: TranscriptionDependencies(settings: settings, credentials: credentials, delivery: delivery, timing: timing),
            queueLimits: queueLimits)
        if let concurrency { try app.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency)) }
    }
    func record() async throws -> UUID {
        #expect(await app.startRecording())
        guard case .recording(let id, _) = app.state else { throw QueueTestError.recording }
        source.emit(testAudio())
        await app.finishRecording()
        return id
    }
    func remove() { source.stop(); app.stopProcessing(); timing.cancelAll(); server.stop(); try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class QueueMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    var holdAuthorization = false
    var audioOnStart: PCMChunk?
    private(set) var startCount = 0
    private var permission: CheckedContinuation<MicrophoneAuthorization, Never>?
    private var stream: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization {
        if holdAuthorization { return await withCheckedContinuation { permission = $0 } }
        return authorization
    }
    func completeAuthorization(_ value: MicrophoneAuthorization) {
        authorization = value
        holdAuthorization = false
        permission?.resume(returning: value)
        permission = nil
    }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        startCount += 1
        let next = AsyncThrowingStream<PCMChunk, Error> { stream = $0 }
        if let audioOnStart { stream?.yield(audioOnStart) }
        return next
    }
    func emit(_ chunk: PCMChunk) { stream?.yield(chunk) }
    func stop() { stream?.finish(); stream = nil }
}

@MainActor
private final class QueueDocumentDelivery: TextDelivering {
    let document = NSTextView()
    let otherDocument = NSTextView()
    var focusedOther = false
    var result = TextDeliveryResult.delivered
    var copied = "用户等待时复制的新内容"
    private struct Snapshot { let other: Bool; var text: String; var range: NSRange }
    private var targets: [UUID: Snapshot] = [:]
    func captureTarget() -> TextDeliveryTarget? {
        let target = TextDeliveryTarget()
        let field = focusedOther ? otherDocument : document
        targets[target.id] = Snapshot(other: focusedOther, text: field.string, range: field.selectedRange())
        return target
    }
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard let before = targets[target.id], before.other == focusedOther else { return .manual }
        let field = focusedOther ? otherDocument : document
        guard before.text == field.string, before.range == field.selectedRange() else { return .manual }
        guard result != .manual else { return .manual }
        field.insertText(text, replacementRange: field.selectedRange())
        if result == .uncertain { return .uncertain }
        for (id, snapshot) in targets where snapshot.other == before.other && snapshot.text == before.text && snapshot.range == before.range {
            targets[id] = Snapshot(other: before.other, text: field.string, range: field.selectedRange())
        }
        return .delivered
    }
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult {
        guard let target = captureTarget() else { return .manual }
        defer { releaseTarget(target) }
        return deliver(text, to: target)
    }
    func releaseTarget(_ target: TextDeliveryTarget) { targets[target.id] = nil }
    func copy(_ text: String) { copied = text }
}

private final class QueueLoopbackServer: @unchecked Sendable {
    struct Request: Sendable { let body: Data; let authorization: String?; let path: String }
    private let lock = NSLock()
    private var captured: [Request] = []
    private var connections: [Int32] = []
    private var stopped = false
    private let listener: Int32
    let baseURL: String
    var requests: [Request] { lock.withLock { captured } }
    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard listener >= 0 else { throw QueueTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 16) == 0 else { close(listener); throw QueueTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard named == 0 else { close(listener); throw QueueTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "queue-controlled-listener").async { [self] in
            defer { close(listener) }
            while !lock.withLock({ stopped }) {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }
    func reply(index: Int, text: String, status: Int = 200) {
        let connection = lock.withLock { connections[index] }
        let body = try! JSONSerialization.data(withJSONObject: ["text": text])
        let header = Data("HTTP/1.1 \(status) Controlled\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        var signal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &signal, socklen_t(MemoryLayout<Int32>.size))
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
    func stop() {
        let pending = lock.withLock { stopped = true; return connections }
        shutdown(listener, SHUT_RDWR)
        pending.forEach { shutdown($0, SHUT_RDWR); close($0) }
    }
    private func receive(_ connection: Int32) {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?
        var expected = 0
        var authorization: String?
        var path = ""
        while bytes.count < 2 * 1_024 * 1_024 {
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
            if let headerEnd, bytes.count - headerEnd >= expected {
                lock.withLock { captured.append(Request(body: Data(bytes.dropFirst(headerEnd).prefix(expected)), authorization: authorization, path: path)); connections.append(connection) }
                return
            }
        }
        close(connection)
    }
}
private enum QueueTestError: Error { case socket, recording }

private func seedEncryptedPendingAudio(_ template: Data, templateID: UUID, vault: URL) throws {
    let key = SymmetricKey(data: TestDataKey().bytes)
    let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: template.dropFirst(6)), using: key,
                                  authenticating: Data("\(templateID)/entry".utf8))
    let original = try #require(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
    let pcm = Data(repeating: 0x32, count: 8_192)
    for order in 2...3 {
        let id = UUID()
        let directory = vault.appendingPathComponent("history/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entry = try #require(original["entry"] as? [String: Any])
        entry["id"] = id.uuidString
        entry["sampleRate"] = 48_000
        entry["frameCount"] = 14_336_000
        entry["disposition"] = "awaitingProcessing"
        entry["transcription"] = NSNull()
        entry["rawTranscription"] = NSNull()
        entry["delivery"] = NSNull()
        entry["recordingOrder"] = order
        entry["queueStage"] = "waitingForSlot"
        let metadata = try JSONSerialization.data(withJSONObject: ["entry": entry, "chunkCount": 3_500])
        try sealQueueFixture(metadata, to: directory.appendingPathComponent("entry.enc"), context: "\(id)/entry", key: key)
        for index in 0..<3_500 {
            try sealQueueFixture(pcm, to: directory.appendingPathComponent(String(format: "%08d.audio", index)),
                                 context: "\(id)/audio/\(index)", key: key)
        }
    }
    try sealQueueFixture(JSONEncoder().encode(UInt64(3)), to: vault.appendingPathComponent("recording-order.enc"),
                         context: "recording-order-v1", key: key)
}

private func sealQueueFixture(_ data: Data, to path: URL, context: String, key: SymmetricKey) throws {
    let sealed = try #require(AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined)
    try (Data("QDENC1".utf8) + sealed).write(to: path)
}

@MainActor
private final class BoundedQueueMicrophone: AudioCapturing {
    var authorization = MicrophoneAuthorization.authorized
    private var producer: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
    func start() throws -> AsyncThrowingStream<PCMChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        self.continuation = continuation
        producer = Task.detached {
            let chunk = PCMChunk(samples: Data(repeating: 0x52, count: 8_192), sampleRate: 48_000)
            for index in 0..<120 {
                guard !Task.isCancelled else { break }
                if case .dropped = continuation.yield(chunk) {
                    print("BOUNDED_QUEUE_CAPTURE overrunAtChunk=\(index)")
                    continuation.finish(throwing: AudioCaptureError.captureOverrun)
                    return
                }
                do { try await Task.sleep(for: .seconds(4_096.0 / 48_000.0)) }
                catch { break }
            }
            continuation.finish()
        }
        return stream
    }
    func stop() { producer?.cancel(); continuation?.finish() }
}

private func actualAudioFootprint(_ vault: URL) throws -> UInt64 { try actualLocalFootprint(vault, onlyAudio: true) }

private func actualLocalFootprint(_ vault: URL, onlyAudio: Bool = false) throws -> UInt64 {
    let iterator = try #require(FileManager.default.enumerator(at: vault,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]))
    var total: UInt64 = 0
    for case let path as URL in iterator {
        if onlyAudio && path.pathExtension != "audio" { continue }
        let info = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        if info.isRegularFile == true {
            total += UInt64(max(try #require(info.fileSize), try #require(info.totalFileAllocatedSize)))
        }
    }
    return total
}
