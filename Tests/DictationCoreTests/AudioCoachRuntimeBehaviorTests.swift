import Foundation
import Testing
import DictationCore

@Suite(.serialized)
@MainActor
struct AudioCoachRuntimeBehaviorTests {
    @Test
    func preparedAudioUsesTheLatestServiceKeyModelPromptAndReducedActualConcurrency() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        let latestServer = try ArtifactLoopbackServer()
        defer { latestServer.stop(); f.remove() }
        try f.coachSettings.save(.init(enabled: true, inputMode: .originalAudio))
        for index in 0..<3 {
            _ = try await f.record()
            f.server.reply(try await f.request(.asr, ordinal: index), object: ["text": "Raw audio segment \(index)."])
            try await artifactWait { (try? f.app.history().filter { $0.rawTranscription != nil }.count) == index + 1 }
        }
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "before-coach"),
            concurrency: 3, inputMode: .originalAudio))
        f.app.configurationChanged()
        #expect(f.app.coachScheduler?.inFlightCount == 3)
        #expect(f.server.requests.filter { $0.role == .coach }.isEmpty)
        let service = ModelService(id: f.serviceID, name: "新音频带教端点", baseURL: latestServer.baseURL, authentication: .bearerToken)
        try f.services.save(.init(services: [service], transcription: .init(serviceID: f.serviceID, model: "artifact-asr")))
        try f.credentials.saveKey("latest-audio-fake-key", for: f.serviceID)
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "latest-coach"),
            concurrency: 1, customPrompt: "最新完整音频带教提示词。", inputMode: .originalAudio))
        f.app.configurationChanged()
        var peakSent = 0
        f.app.onChange = { peakSent = max(peakSent, (try? f.app.history().filter { $0.coach?.status == .inFlight }.count) ?? 0) }
        for index in 0..<3 {
            try await artifactWait { latestServer.requests.count == index + 1 }
            let request = latestServer.requests[index]
            #expect(request.model == "latest-coach" && request.authorization == "Bearer latest-audio-fake-key")
            #expect(request.systemText == "最新完整音频带教提示词。")
            #expect(f.app.mainRequestBudget.activeCount == 0)
            #expect(f.app.coachScheduler?.inFlightCount == 1)
            #expect(f.server.requests.filter { $0.role == .coach }.isEmpty)
            latestServer.replyChat(request, content: "{\"kind\":\"no_card\"}")
        }
        try await artifactWait { f.app.coachScheduler?.inFlightCount == 0 }
        #expect(peakSent == 1 && latestServer.requests.count == 3)
        #expect(try f.app.history().allSatisfy { $0.coach?.status == .succeeded && $0.coach?.dispatch?.audioUsed == true })
    }

    @Test(arguments: ["off", "delete", "cancel", "stop", "prepare", "timeout"])
    func anUnsentAudioWorkerCannotSendOrProduceALateCardAfterItsLifecycleEnds(_ action: String) async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        try f.coachSettings.save(.init(enabled: true, inputMode: .originalAudio))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "A pending audio coaching segment."])
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .waitingForConfiguration }
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "lifecycle-coach"), inputMode: .originalAudio))
        f.app.configurationChanged()
        #expect(f.app.coachScheduler?.inFlightCount == 1)
        #expect(f.server.requests.filter { $0.role == .coach }.isEmpty)
        switch action {
        case "off": try f.app.coachScheduler?.setEnabled(false)
        case "delete": try f.app.deleteHistory(id)
        case "cancel": try f.app.cancelRecordedSegment(id)
        case "stop": f.app.stopProcessing()
        case "prepare": f.app.prepareForTermination()
        default: f.timing.advance(to: 30)
        }
        if action == "timeout" {
            try await artifactWait { (try? f.app.history().first?.coach?.status) == .timedOut }
        }
        for _ in 0..<20 { await Task.yield() }
        f.app.configurationChanged()
        #expect(f.server.requests.filter { $0.role == .coach }.isEmpty)
        #expect(f.app.coachScheduler?.panelState.cards.isEmpty == true)
        #expect(f.app.coachScheduler?.inFlightCount == 0)
        #expect(try f.app.reservedStorageBytes == 0)
    }

    @Test
    func offlineAfterAudioPreparationWaitsAndTheActualRequestKeepsItsEncodingTimeInTheDeadline() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        try f.coachSettings.save(.init(enabled: true, inputMode: .originalAudio))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep the total audio request deadline."])
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .waitingForConfiguration }
        try f.coachSettings.save(.init(enabled: true, role: .init(serviceID: f.serviceID, model: "deadline-coach"), inputMode: .originalAudio))
        f.app.configurationChanged()
        f.timing.advance(to: 4)
        f.network.setAvailable(false)
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .waitingForNetwork }
        #expect(f.app.coachScheduler?.inFlightCount == 0 && f.server.requests.filter { $0.role == .coach }.isEmpty)
        f.timing.advance(to: 100)
        #expect(try f.app.history().first?.coach?.failure != .timedOut)
        f.network.setAvailable(true)
        let request = try await f.request(.coach)
        f.timing.advance(to: 125)
        #expect(try f.app.history().first?.coach?.status == .inFlight)
        f.timing.advance(to: 126)
        try await artifactWait { (try? f.app.history().first?.coach?.status) == .timedOut }
        f.server.replyChat(request, content: "{\"kind\":\"no_card\"}")
        #expect(f.server.requests.filter { $0.role == .coach }.count == 1)
        #expect(f.app.coachScheduler?.panelState.cards.isEmpty == true)
        #expect(try f.app.history().first { $0.id == id }?.coach?.result == nil)
    }

    @Test
    func theRecorderSendsAuthenticatedOriginalAudioOnceAndPersistsRealFluencyEvidence() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        var configuration = try f.coachSettings.load()
        configuration.inputMode = .originalAudio
        try f.coachSettings.save(configuration)
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I pause before saying tomorrow."])
        try await artifactWait {
            let status = try? f.app.history().first?.coach?.status
            return f.server.requests.contains { $0.role == .coach } || status == .failed
        }
        #expect(try f.app.history().first?.coach?.failure == nil)
        guard let request = f.server.requests.first(where: { $0.role == .coach }) else {
            Issue.record("Recorder did not supply the original WAV to the actual coach request.")
            return
        }
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "I pause before saying tomorrow.")
        let audio = try #require(parts.last?["input_audio"] as? [String: String])
        #expect(audio["format"] == "wav")
        let wave = try #require(audio["data"].flatMap { Data(base64Encoded: $0) })
        #expect(wave.dropFirst(44) == testAudio().samples)
        f.server.replyChat(request, content: "{\"kind\":\"card\",\"suggestions\":[{\"category\":\"fluency\",\"improved\":\"Keep the phrase connected.\",\"reason\":\"A pause breaks this short phrase.\",\"audioEvidence\":{\"startSeconds\":0.1,\"endSeconds\":0.3,\"observation\":\"An audible pause between words.\"}}]}")
        try await artifactWait { f.app.coachScheduler?.panelState.cards.count == 1 }
        let entry = try #require(f.app.history().first { $0.id == id })
        #expect(entry.coach?.dispatch?.audioUsed == true)
        #expect(entry.coach?.dispatch?.audioDuration == 0.5)
        let card = try #require(f.app.coachScheduler?.panelState.cards.first)
        #expect(card.inputMode == .originalAudio)
        let favorite = try f.app.favoriteSnapshot(for: card)
        #expect(favorite.feedback.suggestions.first?.audioEvidence?.endSeconds == 0.3)
        #expect(f.server.requests.filter { $0.role == .coach }.count == 1)
    }
}
