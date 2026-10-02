import Foundation
import Testing
import DictationCore

@MainActor
@Suite(.serialized)
struct TranscriptionBehaviorTests {
    @Test
    func rotatingOneServiceNeverCleansACredentialStillReferencedByAnotherSavedService() async throws {
        let server = try ControlledLoopbackServer()
        defer { server.stop() }
        let fixture = try TranscriptionFixture(networkConfiguration: URLSessionConfiguration.ephemeral)
        defer { fixture.remove() }
        let secondID = UUID()
        try fixture.settings.save(ModelConfiguration(services: [
            ModelService(id: fixture.serviceID, name: "服务一", baseURL: server.baseURL + "/first", authentication: .bearerToken),
            ModelService(id: secondID, name: "服务二", baseURL: server.baseURL + "/second", authentication: .bearerToken, credentialID: fixture.serviceID)
        ], transcription: ModelRoleConfiguration(serviceID: fixture.serviceID, model: "fixture-asr")))
        try fixture.credentials.saveKey("fake-shared-original-key", for: fixture.serviceID)
        try fixture.settings.saveTranscriptionService(ModelService(id: fixture.serviceID, name: "服务一", baseURL: server.baseURL + "/new-first", authentication: .bearerToken),
            model: "fixture-asr", timeout: 60, newKey: "fake-rotated-key", credentials: fixture.credentials)
        var configuration = try fixture.settings.load()
        configuration.transcription = ModelRoleConfiguration(serviceID: secondID, model: "fixture-asr")
        try fixture.settings.save(configuration)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { server.requests.count == 1 && (try? fixture.app.history().first?.rawTranscription) == "受控本机转写。" }
        #expect(server.requests.first?.path == "/second/audio/transcriptions")
        #expect(server.requests.first?.authorization == "Bearer fake-shared-original-key")
    }

    @Test
    func anUnsavedFailureRequiresExplicitRetryAfterSpaceAndPermissionsRecover() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        let id = try #require(fixture.app.history().first?.id)
        try fixture.settings.save(ModelConfiguration(services: [ModelService(id: fixture.serviceID, name: "测试服务", baseURL: "https://fixture.invalid/v1", authentication: .bearerToken)],
                                                    transcription: ModelRoleConfiguration(serviceID: fixture.serviceID, model: "fixture-asr")))
        try fixture.credentials.saveKey("fake-key", for: fixture.serviceID)
        let entryDirectory = fixture.history.appendingPathComponent("history/\(id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: entryDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path) }
        fixture.disk.bytes = 1_024
        fixture.app.configurationChanged()
        #expect(try fixture.app.history().first?.transcription?.status == .failed)
        #expect(try fixture.app.history().first?.transcription?.failure == .storageFailure)
        #expect(ProtocolEndpoint.requestCount == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path)
        fixture.disk.bytes = 100 * 1_024 * 1_024
        fixture.app.configurationChanged()
        #expect(try fixture.app.history().first?.transcription?.status == .failed)
        #expect(ProtocolEndpoint.requestCount == 0)
        try fixture.app.retryTranscription(id)
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        #expect(try fixture.app.history().first?.transcription?.status == .inFlight)
        ProtocolEndpoint.reply(text: "用户明确重试后成功。")
        try await waitUntil { (try? fixture.app.history().first?.rawTranscription) == "用户明确重试后成功。" }
    }

    @Test
    func aRealHTTPAuthenticationChallengeKeepsTheAuthenticationReasonWithoutFallback() async throws {
        let server = try ControlledLoopbackServer(challenge: true)
        defer { server.stop() }
        let fixture = try TranscriptionFixture(networkConfiguration: URLSessionConfiguration.ephemeral)
        defer { fixture.remove() }
        try fixture.settings.save(ModelConfiguration(services: [ModelService(id: fixture.serviceID, name: "受控鉴权服务", baseURL: server.baseURL, authentication: .bearerToken)],
                                                    transcription: ModelRoleConfiguration(serviceID: fixture.serviceID, model: "fixture-asr")))
        try fixture.credentials.saveKey("fake-bearer-key", for: fixture.serviceID)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { (try? fixture.app.history().first?.transcription?.status) == .failed }
        #expect(try fixture.app.history().first?.transcription?.failure == .authentication)
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.authorization == "Bearer fake-bearer-key")
        #expect(try fixture.app.history().first?.rawTranscription == nil)
        #expect(fixture.delivery.inserted.isEmpty)
    }

    @Test(arguments: [
        CredentialCommitCase(configurationFails: false, credentialsFail: false, cleanupFails: false,
                             expectedPath: "/new/audio/transcriptions", expectedAuthorization: "Bearer fake-new-endpoint-token"),
        CredentialCommitCase(configurationFails: true, credentialsFail: false, cleanupFails: false,
                             expectedPath: "/old/audio/transcriptions", expectedAuthorization: "Bearer fake-old-endpoint-token"),
        CredentialCommitCase(configurationFails: true, credentialsFail: false, cleanupFails: true,
                             expectedPath: "/old/audio/transcriptions", expectedAuthorization: "Bearer fake-old-endpoint-token"),
        CredentialCommitCase(configurationFails: false, credentialsFail: true, cleanupFails: false,
                             expectedPath: "/old/audio/transcriptions", expectedAuthorization: "Bearer fake-old-endpoint-token")
    ])
    func savingAServiceKeepsItsEndpointAndCredentialTogetherAcrossFailureAndRestart(_ sample: CredentialCommitCase) async throws {
        let server = try ControlledLoopbackServer()
        defer { server.stop() }
        let network = URLSessionConfiguration.ephemeral
        let fixture = try TranscriptionFixture(networkConfiguration: network)
        defer { fixture.remove() }
        try fixture.settings.save(ModelConfiguration(services: [ModelService(id: fixture.serviceID, name: "旧服务", baseURL: server.baseURL + "/old", authentication: .bearerToken)],
                                                    transcription: ModelRoleConfiguration(serviceID: fixture.serviceID, model: "fixture-asr")))
        try fixture.credentials.saveKey("fake-old-endpoint-token", for: fixture.serviceID)
        if sample.configurationFails { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path) }
        fixture.credentials.rejectWrites = sample.credentialsFail
        fixture.credentials.rejectDeletion = sample.cleanupFails
        var rejected = false
        do {
            try fixture.settings.saveTranscriptionService(ModelService(id: fixture.serviceID, name: "新服务", baseURL: server.baseURL + "/new", authentication: .bearerToken),
                model: "fixture-asr", timeout: 60, newKey: "fake-new-endpoint-token", credentials: fixture.credentials)
        } catch { rejected = true }
        #expect(rejected == (sample.configurationFails || sample.credentialsFail))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        fixture.credentials.rejectWrites = false
        fixture.credentials.rejectDeletion = false
        let reopenedSettings = ServiceSettings(file: fixture.root.appendingPathComponent("configuration.json"))
        #expect(try reopenedSettings.load().services.first?.id == fixture.serviceID)
        let source = ControlledMicrophone()
        let restarted = RecordingApplication(source: source, historyDirectory: fixture.history, keys: TestDataKey(),
            transcription: TranscriptionDependencies(settings: reopenedSettings, credentials: fixture.credentials,
                networkConfiguration: network, delivery: fixture.delivery, timing: fixture.timing))
        defer { restarted.stopProcessing() }
        #expect(await restarted.startRecording())
        source.emit(testAudio())
        await restarted.finishRecording()
        try await waitUntil { server.requests.count == 1 && (try? restarted.history().first?.rawTranscription) == "受控本机转写。" }
        let request = try #require(server.requests.first)
        #expect(request.path == sample.expectedPath)
        #expect(request.authorization == sample.expectedAuthorization)
        let ordinaryJSON = try String(contentsOf: fixture.root.appendingPathComponent("configuration.json"), encoding: .utf8)
        #expect(!ordinaryJSON.contains("fake-new-endpoint-token"))
        #expect(!ordinaryJSON.contains("fake-old-endpoint-token"))
    }

    @Test
    func aRestartShowsTheUnconfirmedRequestAndNeverSendsItUntilExplicitRetry() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        fixture.app.stopProcessing()
        try await waitUntil { ProtocolEndpoint.stopCount == 1 }
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProtocolEndpoint.self]
        let restarted = RecordingApplication(source: ControlledMicrophone(), historyDirectory: fixture.history, keys: TestDataKey(),
            transcription: TranscriptionDependencies(settings: fixture.settings, credentials: fixture.credentials,
                networkConfiguration: network, delivery: fixture.delivery, timing: fixture.timing))
        defer { restarted.stopProcessing() }
        let entry = try #require(restarted.history().first)
        #expect(entry.transcription?.status == .interrupted)
        restarted.configurationChanged()
        #expect(ProtocolEndpoint.requestCount == 1)
        try restarted.retryTranscription(entry.id)
        try await waitUntil { ProtocolEndpoint.requestCount == 2 }
        ProtocolEndpoint.reply(text: "重启后手动恢复的原文。", index: 1)
        try await waitUntil { (try? restarted.history().first?.delivery) == .manual }
        #expect(try restarted.rawTranscription(entry.id) == "重启后手动恢复的原文。")
        #expect(fixture.delivery.inserted.isEmpty)
    }

    @Test(arguments: [
        ProtocolFailureCase(status: 401, body: "{\"error\":{\"message\":\"fake-key must not reach UI\"}}", expected: .authentication),
        ProtocolFailureCase(status: 429, body: "{\"error\":{\"code\":\"insufficient_quota\"}}", expected: .quota),
        ProtocolFailureCase(status: 429, body: "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", expected: .rateLimited),
        ProtocolFailureCase(status: 404, body: "{\"error\":{\"message\":\"model unsupported\"}}", expected: .incompatible),
        ProtocolFailureCase(status: 200, body: "{\"text\":\"  \\n \\t\"}", expected: .emptyResult),
        ProtocolFailureCase(status: 200, body: "{\"choices\":[{\"text\":\"wrong role response\"}]}", expected: .incompatible)
    ])
    func protocolFailuresPreserveAudioAndNeverRetryOrExposeProviderMessages(_ sample: ProtocolFailureCase) async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        ProtocolEndpoint.respond(status: sample.status, body: Data(sample.body.utf8))
        try await waitUntil { (try? fixture.app.history().first?.transcription?.status) == .failed }
        #expect(try fixture.app.history().first?.transcription?.failure == sample.expected)
        fixture.app.configurationChanged()
        #expect(ProtocolEndpoint.requestCount == 1)
        #expect(try fixture.app.history().first?.frameCount == 4_000)
        #expect(try fixture.app.history().first?.rawTranscription == nil)
        #expect(fixture.delivery.inserted.isEmpty)
        #expect(fixture.app.notice?.contains("fake-key") == false)
    }

    @Test(arguments: [false, true])
    func responseSizeIsLimitedBeforeBufferingEitherWithOrWithoutADeclaredLength(_ declared: Bool) async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        ProtocolEndpoint.beginResponse(body: declared ? Data() : Data(repeating: 0x41, count: 1_024 * 1_024 + 1),
                                       headers: declared ? ["Content-Length": "1048577"] : [:])
        try await waitUntil { (try? fixture.app.history().first?.transcription?.failure) == .responseTooLarge && ProtocolEndpoint.stopCount == 1 }
        #expect(try fixture.app.history().first?.rawTranscription == nil)
        #expect(fixture.delivery.inserted.isEmpty)
    }

    @Test
    func oversizedValidTextIsNotSavedOrDelivered() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(authentication: .none)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        ProtocolEndpoint.reply(text: String(repeating: "A", count: 256 * 1_024 + 1))
        try await waitUntil { (try? fixture.app.history().first?.transcription?.failure) == .resultTooLarge }
        #expect(fixture.delivery.inserted.isEmpty)
        #expect(try fixture.app.history().first?.rawTranscription == nil)
    }

    @Test
    func failedResultPersistenceDoesNotClaimTheTextIsDownloadableOrSendItToTheTarget() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let id = try #require(fixture.app.history().first?.id)
        let entryDirectory = fixture.history.appendingPathComponent("history/\(id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: entryDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path) }
        ProtocolEndpoint.reply(text: "这个结果未能持久化。")
        try await waitUntil { (try? fixture.app.history().first?.transcription?.failure) == .storageFailure }
        #expect(throws: DictationError.missingHistory) { try fixture.app.rawTranscription(id) }
        #expect(fixture.delivery.inserted.isEmpty)
        fixture.app.configurationChanged()
        #expect(ProtocolEndpoint.requestCount == 1)
        let output = fixture.root.appendingPathComponent("not-saved.txt")
        #expect(throws: DictationError.missingHistory) { try fixture.app.exportRawTranscription(id, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func deletingHistoryInvalidatesACompletionAlreadySentByTheProtocol() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let id = try #require(fixture.app.history().first?.id)
        ProtocolEndpoint.reply(text: "删除前已返回但未交付。")
        try fixture.app.deleteHistory(id)
        #expect(try fixture.app.history().isEmpty)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 2 }
        ProtocolEndpoint.reply(text: "删除后的新片段。", index: 1)
        try await waitUntil { (try? fixture.app.history().first?.rawTranscription) == "删除后的新片段。" }
        #expect(try fixture.app.history().count == 1)
        #expect(fixture.delivery.inserted == ["删除后的新片段。"])
        #expect(!FileManager.default.fileExists(atPath: fixture.history.appendingPathComponent("history/\(id)").path))
    }

    @Test
    func aLateCompletedBodyCannotOverwriteTheExplicitRetryOrReachTheTarget() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let id = try #require(fixture.app.history().first?.id)
        ProtocolEndpoint.reply(text: "旧尝试迟到文本")
        fixture.timing.advance(to: 60)
        fixture.app.checkRecordingConditions()
        #expect(try fixture.app.history().first?.transcription?.status == .timedOut)
        try fixture.app.retryTranscription(id)
        try await waitUntil { ProtocolEndpoint.requestCount == 2 }
        ProtocolEndpoint.reply(text: "新尝试有效文本", index: 1)
        try await waitUntil { (try? fixture.app.history().first?.rawTranscription) == "新尝试有效文本" }
        #expect(fixture.delivery.inserted == ["新尝试有效文本"])
    }

    @Test
    func controlCharactersAreRejectedWithNoAuthenticationAndAudioIsRetained() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(authentication: .none)
        var configuration = try fixture.settings.load()
        configuration.services[0].baseURL = "http://127.0.0.1:12345/v1"
        try fixture.settings.save(configuration)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        #expect(ProtocolEndpoint.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(ProtocolEndpoint.requests.first?.url?.absoluteString == "http://127.0.0.1:12345/v1/audio/transcriptions")
        ProtocolEndpoint.reply(text: "\u{0}\u{1}")
        try await waitUntil { (try? fixture.app.history().first?.transcription?.status) == .failed }
        let entry = try #require(fixture.app.history().first)
        #expect(entry.transcription?.failure == .emptyResult)
        #expect(entry.rawTranscription == nil)
        #expect(fixture.delivery.inserted.isEmpty)
        #expect(entry.frameCount == 4_000)
    }

    @Test
    func anUncertainWriteCannotBeRepeatedAndCopyingDoesNotConfirmDelivery() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        fixture.delivery.result = .uncertain
        fixture.delivery.copied = "用户等待时新复制的文本"
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        ProtocolEndpoint.reply(text: "结果可能已插入。")
        try await waitUntil { (try? fixture.app.history().first?.delivery) == .uncertain }
        let entry = try #require(fixture.app.history().first)
        #expect(fixture.delivery.copied == "用户等待时新复制的文本")
        #expect(throws: DictationError.deliveryUncertain) { try fixture.app.insertRawTranscriptionAtCurrentCursor(entry.id) }
        try fixture.app.copyRawTranscription(entry.id)
        #expect(try fixture.app.history().first?.disposition == .awaitingProcessing)
        try fixture.app.confirmManuallyDelivered(entry.id)
        #expect(try fixture.app.history().first?.disposition == .completed)
    }

    @Test
    func missingCredentialsKeepAudioAndRepairDispatchesTheLatestServiceModelAndKey() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure()
        #expect(fixture.app.transcriptionReadiness == .missingCredentials)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        #expect(try fixture.app.history().first?.transcription?.status == .waitingForConfiguration)
        #expect(ProtocolEndpoint.requestCount == 0)
        let latestID = UUID()
        try fixture.settings.save(ModelConfiguration(services: [ModelService(id: latestID, name: "新服务", baseURL: "https://latest.invalid/api", authentication: .bearerToken)],
                                                    transcription: ModelRoleConfiguration(serviceID: latestID, model: "new-asr")))
        try fixture.credentials.saveKey("fake-latest-key", for: latestID)
        #expect(fixture.app.transcriptionReadiness == nil)
        fixture.app.configurationChanged()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let request = try #require(ProtocolEndpoint.requests.first)
        #expect(request.url?.absoluteString == "https://latest.invalid/api/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-latest-key")
        #expect(request.httpBody?.range(of: Data("\r\n\r\nnew-asr\r\n".utf8)) != nil)
        ProtocolEndpoint.reply(text: "采用最新配置。")
        try await waitUntil { (try? fixture.app.history().first?.rawTranscription) == "采用最新配置。" }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("configuration.json"), encoding: .utf8).contains("fake-latest-key") == false)
    }

    @Test
    func theWholeDeadlineIncludesAnIncompleteResponseAndAnExplicitRetryUsesANewAttempt() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-old-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let entry = try #require(fixture.app.history().first)
        let oldAttempt = entry.transcription?.attemptID
        ProtocolEndpoint.beginResponse(body: Data("{\"text\":\"尚未完成".utf8))
        fixture.timing.advance(to: 59)
        #expect(try fixture.app.history().first?.transcription?.status == .inFlight)
        fixture.timing.advance(to: 60)
        try await waitUntil { (try? fixture.app.history().first?.transcription?.status) == .timedOut && ProtocolEndpoint.stopCount == 1 }
        #expect(try fixture.app.history().first?.rawTranscription == nil)
        try fixture.credentials.saveKey("fake-new-key", for: fixture.serviceID)
        try fixture.app.retryTranscription(entry.id)
        try await waitUntil { ProtocolEndpoint.requestCount == 2 }
        #expect(try fixture.app.history().first?.transcription?.attemptID != oldAttempt)
        #expect(ProtocolEndpoint.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-new-key")
        ProtocolEndpoint.reply(text: "重试有效文本。", index: 1)
        try await waitUntil { (try? fixture.app.history().first?.rawTranscription) == "重试有效文本。" }
        #expect(fixture.delivery.inserted == ["重试有效文本。"])
    }

    @Test
    func cancellingTheNextRecordingLeavesThePreviousRequestRunningAndRecordedCancellationStopsIt() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let first = try #require(fixture.app.history().first)
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.cancelCurrentRecording()
        #expect(ProtocolEndpoint.stopCount == 0)
        #expect(try fixture.app.history().count == 1)
        try fixture.app.cancelRecordedSegment(first.id)
        try await waitUntil { ProtocolEndpoint.stopCount == 1 }
        #expect(try fixture.app.history().first?.transcription?.status == .cancelled)
        #expect(try fixture.app.history().first?.rawTranscription == nil)
        #expect(fixture.delivery.inserted.isEmpty)
    }

    @Test
    func focusChangesKeepRawTextForManualCopyWithoutClaimingDelivery() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        fixture.delivery.unchanged = false
        ProtocolEndpoint.reply(text: "焦点变化后仍可取回。")
        try await waitUntil { (try? fixture.app.history().first?.delivery) == .manual }
        let entry = try #require(fixture.app.history().first)
        try fixture.app.copyRawTranscription(entry.id)
        #expect(fixture.delivery.copied == "焦点变化后仍可取回。")
        #expect(fixture.delivery.inserted.isEmpty)
        #expect(try fixture.app.history().first?.disposition == .awaitingProcessing)
    }

    @Test
    func aRecordedSegmentSendsOnlyItsAudioAndStoresTheRawTranscriptBeforeSafeDelivery() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        try fixture.configure(key: "fake-initial-key")
        #expect(await fixture.app.startRecording())
        fixture.source.emit(testAudio())
        await fixture.app.finishRecording()
        try await waitUntil { ProtocolEndpoint.requestCount == 1 }
        let request = try #require(ProtocolEndpoint.requests.first)
        #expect(request.url?.path == "/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-initial-key")
        let body = try #require(request.httpBody)
        #expect(body.range(of: Data("name=\"model\"\r\n\r\nfixture-asr".utf8)) != nil)
        #expect(body.range(of: testAudio().samples) != nil)
        #expect(body.range(of: Data("private-window-text".utf8)) == nil)
        ProtocolEndpoint.reply(text: "本段已成功转写。")
        try await waitUntil { fixture.delivery.inserted == ["本段已成功转写。"] }
        let entry = try #require(fixture.app.history().first)
        #expect(entry.disposition == .completed)
        #expect(try fixture.app.rawTranscription(entry.id) == "本段已成功转写。")
        let persisted = try savedFiles(fixture.history)
        #expect(persisted.values.allSatisfy { $0.starts(with: Data("QDENC1".utf8)) })
        #expect(persisted.values.allSatisfy { $0.range(of: Data("本段已成功转写。".utf8)) == nil })
        #expect(persisted.values.allSatisfy { $0.range(of: Data("fake-initial-key".utf8)) == nil })
        let output = fixture.root.appendingPathComponent("raw.txt")
        try fixture.app.exportRawTranscription(entry.id, to: output)
        #expect(try String(contentsOf: output, encoding: .utf8) == "本段已成功转写。")
    }
}

@MainActor
final class TranscriptionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = ControlledMicrophone()
    let credentials = TestServiceCredentials()
    let delivery = ControlledTextDelivery()
    let timing = ControlledRequestTiming()
    let disk = ControlledDiskSpace()
    let serviceID = UUID()
    let settings: ServiceSettings
    let app: RecordingApplication
    var history: URL { root.appendingPathComponent("vault") }
    init(networkConfiguration: URLSessionConfiguration? = nil) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = ServiceSettings(file: root.appendingPathComponent("configuration.json"))
        let configuration = networkConfiguration ?? URLSessionConfiguration.ephemeral
        if networkConfiguration == nil { configuration.protocolClasses = [ProtocolEndpoint.self]; ProtocolEndpoint.reset() }
        let disk = self.disk
        app = RecordingApplication(source: source, historyDirectory: root.appendingPathComponent("vault"), keys: TestDataKey(), diskSpace: { _ in disk.bytes },
                                   transcription: TranscriptionDependencies(settings: settings, credentials: credentials,
                                       networkConfiguration: configuration, delivery: delivery, timing: timing))
    }
    func configure(key: String? = nil, authentication: ServiceAuthentication = .bearerToken) throws {
        try settings.save(ModelConfiguration(services: [ModelService(id: serviceID, name: "测试服务", baseURL: "https://fixture.invalid/v1", authentication: authentication)],
                                             transcription: ModelRoleConfiguration(serviceID: serviceID, model: "fixture-asr")))
        if let key { try credentials.saveKey(key, for: serviceID) }
        app.configurationChanged()
    }
    func remove() { app.stopProcessing(); timing.cancelAll(); ProtocolEndpoint.reset(); try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class TestServiceCredentials: ServiceCredentialStoring {
    var keys: [UUID: String] = [:]
    var rejectWrites = false
    var rejectDeletion = false
    func key(for serviceID: UUID) throws -> String? { keys[serviceID] }
    func saveKey(_ key: String?, for serviceID: UUID) throws {
        if key == nil ? rejectDeletion : rejectWrites { throw TranscriptionFailure.credentialsUnavailable }
        keys[serviceID] = key
    }
}

@MainActor
final class ControlledTextDelivery: TextDelivering {
    var unchanged = true
    var inserted: [String] = []
    var copied: String?
    var result = TextDeliveryResult.delivered
    func captureTarget() -> TextDeliveryTarget? { TextDeliveryTarget() }
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard unchanged else { return .manual }
        if result == .delivered { inserted.append(text) }
        return result
    }
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult { inserted.append(text); return result }
    func releaseTarget(_ target: TextDeliveryTarget) {}
    func copy(_ text: String) { copied = text }
}

@MainActor
final class ControlledRequestTiming: RequestTiming {
    var instant: TimeInterval = 0
    private var waiters: [(TimeInterval, CheckedContinuation<Void, any Error>)] = []
    func wait(until deadline: TimeInterval) async throws {
        if instant >= deadline { return }
        try await withCheckedThrowingContinuation { waiters.append((deadline, $0)) }
    }
    func advance(to value: TimeInterval) {
        instant = value
        let due = waiters.filter { $0.0 <= value }
        waiters.removeAll { $0.0 <= value }
        due.forEach { $0.1.resume() }
    }
    func cancelAll() { let pending = waiters; waiters = []; pending.forEach { $0.1.resume(throwing: CancellationError()) } }
}

final class ProtocolEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: [ProtocolEndpoint] = []
    nonisolated(unsafe) private static var received: [URLRequest] = []
    nonisolated(unsafe) private static var stopped = 0
    static var requests: [URLRequest] { lock.withLock { received } }
    static var requestCount: Int { requests.count }
    static var stopCount: Int { lock.withLock { stopped } }
    static func reset() { lock.withLock { active = []; received = []; stopped = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.withLock { Self.active.append(self); Self.received.append(captured) }
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
    static func beginResponse(body: Data, index: Int = 0, status: Int = 200, headers: [String: String] = [:]) {
        let pending = lock.withLock { active[index] }
        pending.client?.urlProtocol(pending, didReceive: HTTPURLResponse(url: pending.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { current, _ in current })!, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(pending, didLoad: body)
    }
    static func reply(text: String, index: Int = 0) {
        let body = try! JSONSerialization.data(withJSONObject: ["text": text])
        respond(status: 200, body: body, index: index)
    }
    static func respond(status: Int, body: Data, index: Int = 0) {
        let pending = lock.withLock { active[index] }
        beginResponse(body: body, index: index, status: status)
        pending.client?.urlProtocolDidFinishLoading(pending)
    }
}

struct ProtocolFailureCase: Sendable {
    let status: Int
    let body: String
    let expected: TranscriptionFailure
}

struct CredentialCommitCase: Sendable {
    let configurationFails: Bool
    let credentialsFail: Bool
    let cleanupFails: Bool
    let expectedPath: String
    let expectedAuthorization: String
}
