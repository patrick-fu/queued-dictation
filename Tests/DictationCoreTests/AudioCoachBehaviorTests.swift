import AVFoundation
import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite(.serialized)
struct AudioCoachBehaviorTests {
    @Test
    func aControlledAudioModelReceivesTheExactWAVAndRawTextInOneRequest() async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        var updates: [CoachWorkUpdate] = []
        let segmentID = UUID()
        var audioReads: [UUID] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { id in audioReads.append(id); return wave },
            onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: segmentID, rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        let received = try #require(server.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: received.body) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "stream"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts.first?["type"] as? String == "text")
        #expect(parts.first?["text"] as? String == "I goes to work.")
        let audio = try #require(parts.last?["input_audio"] as? [String: String])
        #expect(parts.last?["type"] as? String == "input_audio")
        #expect(audio["format"] == "wav")
        #expect(Data(base64Encoded: try #require(audio["data"])) == wave)
        server.reply(content: audioCoachCardJSON)
        try await waitUntil { scheduler.inFlightCount == 0 }
        let card = try #require(scheduler.panelState.cards.first)
        #expect(audioReads == [segmentID])
        #expect(card.identity.segmentID == segmentID)
        #expect(card.inputMode == .originalAudio)
        #expect(card.rawText == "I goes to work.")
        #expect(card.feedback.suggestions.map(\.category) == [.grammar, .fluency])
        #expect(card.feedback.suggestions[1].audioEvidence == CoachAudioEvidence(startSeconds: 0.1, endSeconds: 0.4,
            observation: "两个词之间有一段明显停顿。"))
        let dispatch = try #require(updates.last?.dispatch)
        #expect(dispatch.audioUsed && dispatch.audioFormat == "wav" && dispatch.audioDuration == 1)
        #expect(updates.last?.result == .card(card.feedback))
        let persisted = String(decoding: try JSONEncoder().encode(updates), as: UTF8.self)
        #expect(!persisted.contains(wave.base64EncodedString()))
        #expect(!persisted.contains("fake-audio-coach-key"))
        #expect(server.requests.count == 1)
    }

    @Test
    func textModeReadsNoAudioAndRejectsAClaimedAudioObservation() async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var reads = 0, updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in reads += 1; throw CoachFailure.invalidAudio },
            onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests[0].body) as? [String: Any])
        #expect((body["messages"] as? [[String: String]])?.last?["content"] == "I goes to work.")
        server.reply(content: audioCoachCardJSON)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(reads == 0)
        #expect(updates.last?.dispatch?.audioUsed == false)
        #expect(updates.last?.dispatch?.audioDuration == nil)
        #expect(updates.last?.failure == .invalidResult)
        #expect(scheduler.panelState.cards.isEmpty)
        try scheduler.configurationChanged()
        #expect(server.requests.count == 1)
    }

    @Test
    func heldWorkReadsNoAudioOrCredentialsAndUsesTheLatestInputModeWhenReleased() async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        var allowed = false, reads = 0, updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, canDispatch: { _ in allowed },
            audioForSegment: { _ in reads += 1; return wave }, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        #expect(reads == 0 && fixture.credentials.reads == 0)
        #expect(updates.last?.status == .waitingForResume)
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        configuration.role?.model = "latest-audio-model"
        try fixture.settings.save(configuration)
        fixture.timing.advance(to: 1_000)
        allowed = true
        try scheduler.configurationChanged()
        try await waitUntil { server.requests.count == 1 }
        #expect(reads == 1 && fixture.credentials.reads == 1)
        #expect(updates.last?.dispatch?.model == "latest-audio-model")
        #expect(updates.last?.dispatch?.audioUsed == true)
        server.reply(content: #"{"kind":"no_card"}"#)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(updates.last?.result == .noCard && scheduler.panelState.cards.isEmpty)
    }

    @Test
    func bothModesShareTheSameThreeSlotsAndCardsKeepTheirActualDispatchMode() async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        var reads = 0, updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in reads += 1; return wave },
            onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try scheduler.enqueue(segmentID: id, rawText: "I goes to work. Segment \(index).") }
        try await waitUntil { server.requests.count == 3 }
        #expect(scheduler.inFlightCount == 3 && scheduler.pendingCount == 1 && reads == 3)
        configuration.inputMode = .text
        configuration.role?.model = "latest-text-model"
        try fixture.settings.save(configuration)
        try scheduler.configurationChanged()
        #expect(reads == 3 && scheduler.pendingCount == 1)
        server.reply(content: audioCoachCardJSON, index: 1)
        try await waitUntil { server.requests.count == 4 && scheduler.panelState.cards.count == 1 }
        #expect(reads == 3 && scheduler.inFlightCount == 3)
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests[3].body) as? [String: Any])
        #expect(body["model"] as? String == "latest-text-model")
        #expect((body["messages"] as? [[String: String]])?.last?["content"] == "I goes to work. Segment 3.")
        server.reply(content: #"{"kind":"card","suggestions":[{"category":"grammar","original":"I goes","improved":"I go","reason":"第一人称使用 go。"}]}"#, index: 3)
        try await waitUntil { scheduler.panelState.cards.count == 2 }
        #expect(scheduler.panelState.cards.map(\.inputMode) == [.originalAudio, .text])
        #expect(scheduler.panelState.cards.last?.id == ids[3])
        #expect(updates.filter { $0.status == .inFlight }.map { $0.dispatch?.audioUsed } == [true, true, true, false])
    }

    @Test(arguments: [
        AudioCoachResponseCase(content: #"{"kind":"no_card"}"#),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","original":"I goes","improved":"I go","reason":"缩短停顿。"}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","improved":"连读。","reason":"中间停顿。","audioEvidence":{"startSeconds":0,"endSeconds":1.01,"observation":"中间停顿。"}}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","improved":"连读。","reason":"中间停顿。","audioEvidence":{"startSeconds":-0.1,"endSeconds":0.4,"observation":"中间停顿。"}}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","improved":"连读。","reason":"中间停顿。","audioEvidence":{"startSeconds":0.4,"endSeconds":0.4,"observation":"中间停顿。"}}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","improved":"连读。","reason":"中间停顿。","audioEvidence":{"startSeconds":false,"endSeconds":true,"observation":"中间停顿。"}}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","original":"I goes","improved":"连读。","reason":"中间停顿。","audioEvidence":{"startSeconds":0.1,"endSeconds":0.4,"observation":"中间停顿。"}}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"no_card","score":80}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"grammar","original":"You goes","improved":"You go","reason":"主谓一致。"}]}"#, failure: .invalidResult),
        AudioCoachResponseCase(content: "unsupported audio", failure: .audioIncompatible, status: 400),
        AudioCoachResponseCase(content: "bad key", failure: .authentication, status: 401)
    ])
    func audioAndSchemaFailuresRemainDistinctAndNeverSendATextFallback(_ sample: AudioCoachResponseCase) async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in wave }, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        server.reply(content: sample.content, status: sample.status)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(updates.last?.failure == sample.failure)
        #expect(updates.last?.result == (sample.failure == nil ? .noCard : nil))
        #expect(scheduler.panelState.cards.isEmpty)
        try scheduler.configurationChanged()
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [AudioCoachUnavailableInput.missing, .unreadable, .malformed, .invalidRate])
    func unavailableOrInvalidAudioFailsBeforeHTTPAndLeavesTextRetryExplicit(_ input: AudioCoachUnavailableInput) async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in
                switch input {
                case .missing: return nil
                case .unreadable: throw CocoaError(.fileReadNoSuchFile)
                case .malformed: return Data("not a WAV".utf8)
                case .invalidRate: return classicCoachWAV(pcm: Data([1, 0]), sampleRate: 1)
                }
            }, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        #expect(updates.last?.status == .failed)
        let expected: CoachFailure = switch input {
        case .missing: .missingAudio
        case .unreadable: .audioUnavailable
        case .malformed, .invalidRate: .invalidAudio
        }
        #expect(updates.last?.failure == expected)
        #expect(scheduler.pendingCount == 0 && scheduler.inFlightCount == 0)
        #expect(server.requests.isEmpty && scheduler.panelState.cards.isEmpty)
        try scheduler.configurationChanged()
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingRoleOrCredentialsWaitsWithoutDecryptingAudio(_ missingCredentials: Bool) throws {
        let fixture = try AudioCoachFixture(baseURL: "http://127.0.0.1:9/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        if missingCredentials { try fixture.credentials.saveKey(nil, for: fixture.serviceID) }
        else { configuration.role = nil }
        try fixture.settings.save(configuration)
        var reads = 0, updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in reads += 1; return nil },
            onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        #expect(reads == 0)
        #expect(updates.last?.status == .waitingForConfiguration)
        #expect(updates.last?.failure == (missingCredentials ? .missingCredentials : .missingConfiguration))
        #expect(fixture.credentials.reads == (missingCredentials ? 1 : 0))
    }

    @Test
    func theAudioDeadlineCoversIncompleteResponseBodiesAndExplicitRetriesUseNewAttempts() async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in wave }, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        let id = UUID(), firstAttempt = UUID(), retryAttempt = UUID()
        try scheduler.enqueue(segmentID: id, rawText: "I goes to work.", attemptID: firstAttempt)
        try await waitUntil { server.requests.count == 1 }
        server.sendResponse(body: Data(#"{"choices":[{"message":{"content":""#.utf8), declaredLength: 400, finish: false)
        fixture.timing.advance(to: 30)
        try await waitUntil { scheduler.inFlightCount == 0 && server.disconnectCount == 1 }
        #expect(updates.last?.status == .timedOut && updates.last?.failure == .timedOut)
        #expect(scheduler.panelState.cards.isEmpty)
        try scheduler.configurationChanged()
        #expect(server.requests.count == 1)
        try scheduler.enqueue(segmentID: id, rawText: "I goes to work.", attemptID: retryAttempt)
        try await waitUntil { server.requests.count == 2 }
        server.reply(content: audioCoachCardJSON, index: 0)
        server.reply(content: audioCoachCardJSON, index: 1)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(scheduler.panelState.cards.map(\.identity.attemptID) == [retryAttempt])
        #expect(!updates.contains { $0.identity.attemptID == firstAttempt && $0.status == .succeeded })
    }

    @Test
    func audioPreparationConsumesTheSameDeadlineBeforeAnyHTTPStarts() throws {
        let fixture = try AudioCoachFixture(baseURL: "http://127.0.0.1:9/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        let wave = classicCoachWAV(pcm: Data([1, 0]), sampleRate: 8_000)
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in fixture.timing.advance(to: 31); return wave },
            onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        #expect(updates.map(\.status) == [.queued, .timedOut])
        #expect(updates.last?.failure == .timedOut && updates.last?.dispatch == nil)
        #expect(scheduler.inFlightCount == 0 && scheduler.panelState.cards.isEmpty)
    }

    @Test(arguments: [AudioCoachInvalidation.disable, .delete, .cancel, .stop])
    func invalidatingAudioCancelsTheRealRequestAndCannotReviveTheOldAttempt(_ action: AudioCoachInvalidation) async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio; configuration.concurrency = 1
        try fixture.settings.save(configuration)
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        let old = UUID(), fresh = UUID()
        var reads: [UUID] = [], updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { id in reads.append(id); return wave },
            onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: old, rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        if action == .disable { try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work. Old pending.") }
        let before = updates
        switch action {
        case .disable: try scheduler.setEnabled(false)
        case .delete: scheduler.removeSegment(old)
        case .cancel: scheduler.cancel(old)
        case .stop: scheduler.stopProcessing()
        }
        try await waitUntil { scheduler.inFlightCount == 0 && server.disconnectCount == 1 }
        #expect(reads == [old] && scheduler.pendingCount == 0)
        if action == .delete || action == .stop { #expect(updates == before) }
        if action == .disable { try scheduler.setEnabled(true) }
        server.reply(content: audioCoachCardJSON, index: 0)
        try scheduler.enqueue(segmentID: fresh, rawText: "I goes to work. Fresh.")
        try await waitUntil { server.requests.count == 2 }
        server.reply(content: audioCoachCardJSON, index: 1)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(scheduler.panelState.cards.map(\.id) == [fresh])
        #expect(!updates.contains { $0.identity.segmentID == old && $0.status == .succeeded })
    }

    @Test
    func disablingDuringPersistenceKeepsValidAudioFeedbackInHistoryWithoutPresentingOrReplayingIt() async throws {
        let server = try AudioCoachLoopbackServer()
        defer { server.stop() }
        let fixture = try AudioCoachFixture(baseURL: server.baseURL + "/v1")
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.inputMode = .originalAudio
        try fixture.settings.save(configuration)
        let wave = try generatedCoachWAV(at: fixture.root.appendingPathComponent("synthetic.wav"))
        var updates: [CoachWorkUpdate] = []
        var scheduler: CoachWorkScheduler!
        scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, audioForSegment: { _ in wave }, onUpdate: { update in
                updates.append(update)
                if update.status == .succeeded { try scheduler.setEnabled(false) }
            })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        server.reply(content: audioCoachCardJSON)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(updates.last?.status == .succeeded && updates.last?.dispatch?.audioUsed == true)
        guard case .card = updates.last?.result else { Issue.record("合法已发送音频结果应保留历史"); return }
        #expect(scheduler.panelState.cards.isEmpty)
        try scheduler.setEnabled(true)
        #expect(scheduler.panelState.cards.isEmpty && server.requests.count == 1)
    }

    @Test
    func sixtyMinutePCMIsSupportedAndLongerOrCorruptWAVIsRejected() throws {
        let fixture = try AudioCoachFixture(baseURL: "http://127.0.0.1:9/v1")
        defer { fixture.remove() }
        let wave = classicCoachWAV(pcm: Data(repeating: 0, count: 57_600_000), sampleRate: 8_000)
        let url = fixture.root.appendingPathComponent("synthetic-sixty-minutes.wav")
        try wave.write(to: url)
        let decoded = try AVAudioFile(forReading: url)
        #expect(decoded.length == 28_800_000 && decoded.fileFormat.sampleRate == 8_000)
        #expect(try AudioCoachInput(wave: wave).duration == 3_600)
        #expect(throws: CoachFailure.audioTooLarge) {
            try AudioCoachInput(wave: classicCoachWAV(pcm: Data(repeating: 0, count: 57_600_002), sampleRate: 8_000))
        }
        #expect(throws: CoachFailure.invalidAudio) { try AudioCoachInput(wave: Data(wave.dropLast())) }
        #expect(throws: CoachFailure.invalidAudio) { try AudioCoachInput(wave: classicCoachWAV(pcm: Data([1]), sampleRate: 8_000)) }
        #expect(AudioCoachInput.maximumWAVBytes == 1_382_465_536)
    }

    @Test
    func oldConfigurationAndDispatchStayTextAndCustomPromptOriginSurvivesModeChanges() throws {
        let legacy = Data(#"{"enabled":false,"concurrency":3,"timeout":30,"corner":"bottomRight"}"#.utf8)
        var configuration = try JSONDecoder().decode(CoachConfiguration.self, from: legacy)
        #expect(configuration.inputMode == .text && configuration.prompt == CoachConfiguration.defaultPrompt)
        configuration.inputMode = .originalAudio
        #expect(configuration.prompt == CoachConfiguration.defaultAudioPrompt)
        configuration.customPrompt = CoachConfiguration.defaultAudioPrompt
        configuration.inputMode = .text
        #expect(configuration.customPrompt == CoachConfiguration.defaultAudioPrompt)
        #expect(configuration.prompt == CoachConfiguration.defaultAudioPrompt)
        let restored = try JSONDecoder().decode(CoachConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored.customPrompt != nil && restored.prompt == CoachConfiguration.defaultAudioPrompt)
        let dispatch = Data(#"{"identity":{"segmentID":"00000000-0000-0000-0000-000000000001","attemptID":"00000000-0000-0000-0000-000000000002"},"serviceID":"00000000-0000-0000-0000-000000000003","model":"old-model","prompt":"old-prompt","timeout":30}"#.utf8)
        let decoded = try JSONDecoder().decode(CoachDispatch.self, from: dispatch)
        #expect(!decoded.audioUsed && decoded.inputMode == .text && decoded.audioDuration == nil && decoded.audioFormat == nil)
    }

    @Test(arguments: ["3.0000000000000001", "0.99999999999999999"])
    func fractionalConcurrencyJSONIsRejectedWithoutRewritingTheConfiguration(_ number: String) throws {
        let fixture = try AudioCoachFixture(baseURL: "http://127.0.0.1:9/v1")
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("fractional-coach.json")
        let original = Data("{\"enabled\":false,\"concurrency\":\(number),\"timeout\":5.75,\"corner\":\"bottomRight\"}".utf8)
        try original.write(to: file)
        let settings = CoachSettings(file: file)
        #expect(throws: CoachFailure.invalidConfiguration) { try settings.load() }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test
    func legitimateIntegerConcurrencyAndFractionalTimeoutRemainCompatible() throws {
        let legacy = Data(#"{"enabled":false,"concurrency":3,"timeout":5.75,"corner":"bottomRight"}"#.utf8)
        let configuration = try JSONDecoder().decode(CoachConfiguration.self, from: legacy)
        #expect(configuration.concurrency == 3 && configuration.timeout == 5.75 && configuration.inputMode == .text)
    }

    @Test
    func audioModeDoesNotSilentlySendTextWhenTheOriginalAudioIsMissing() throws {
        let fixture = try AudioCoachFixture(baseURL: "http://127.0.0.1:9/v1")
        defer { fixture.remove() }
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.settings.load())) as? [String: Any])
        json["inputMode"] = "originalAudio"
        try fixture.settings.save(JSONDecoder().decode(CoachConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
        var request: CoachRequest?
        defer { request?.cancel() }
        #expect(throws: CoachFailure.self) {
            request = try fixture.client.start(segmentID: UUID(), rawText: "I goes to work.") { _ in }
        }
    }
}

@MainActor
private final class AudioCoachFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let serviceID = UUID()
    let settings: CoachSettings
    let services: ServiceSettings
    let credentials = AudioCoachCredentials()
    let timing = ControlledRequestTiming()
    let client: CoachClient
    init(baseURL: String) throws {
        settings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        client = CoachClient(settings: settings, services: services, credentials: credentials, timing: timing)
        try services.save(ModelConfiguration(services: [ModelService(id: serviceID, name: "受控带教服务", baseURL: baseURL, authentication: .bearerToken)]))
        try credentials.saveKey("fake-audio-coach-key", for: serviceID)
        try settings.save(CoachConfiguration(enabled: true, role: ModelRoleConfiguration(serviceID: serviceID, model: "controlled-audio-coach")))
    }
    func remove() { timing.cancelAll(); try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class AudioCoachCredentials: ServiceCredentialStoring {
    private var keys: [UUID: String] = [:]
    private(set) var reads = 0
    func key(for serviceID: UUID) throws -> String? { reads += 1; return keys[serviceID] }
    func saveKey(_ key: String?, for serviceID: UUID) throws { keys[serviceID] = key }
}

private let audioCoachCardJSON = #"{"kind":"card","suggestions":[{"category":"grammar","original":"I goes","improved":"I go","reason":"第一人称使用 go。"},{"category":"fluency","improved":"把 I go 连起来说，在句末停顿。","reason":"短语中间停顿影响连贯性。","audioEvidence":{"startSeconds":0.1,"endSeconds":0.4,"observation":"两个词之间有一段明显停顿。"}}]}"#

private func generatedCoachWAV(at url: URL, seconds: Int = 1) throws -> Data {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8_000)))
    let samples = try #require(buffer.int16ChannelData?.pointee)
    let known: [Int16] = [0, 1_111, -2_222, 32_767, -32_768]
    let intended = (0..<(seconds * 8_000)).map { known[$0 % known.count] }
    for frame in intended.indices { samples[frame] = intended[frame] }
    buffer.frameLength = buffer.frameCapacity
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }
    let decoded = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    #expect(decoded.length == AVAudioFramePosition(seconds * 8_000))
    let read = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: buffer.frameCapacity))
    try decoded.read(into: read)
    let restored = try #require(read.int16ChannelData?.pointee)
    #expect(Array(UnsafeBufferPointer(start: restored, count: Int(read.frameLength))) == intended)
    return try Data(contentsOf: url)
}
private final class AudioCoachLoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let authorization: String?
        let body: Data
        let connection: Int32
    }
    private let lock = NSLock()
    private var received: [Request] = []
    private var disconnected = 0
    private var openConnections: Set<Int32> = []
    private var stopped = false
    private let listener: Int32
    let baseURL: String
    var requests: [Request] { lock.withLock { received } }
    var disconnectCount: Int { lock.withLock { disconnected } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw AudioCoachServerError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { close(listener); throw AudioCoachServerError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(listener); throw AudioCoachServerError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "audio-coach-test-loopback").async { [self] in
            defer { close(listener) }
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                let allowed = lock.withLock {
                    if stopped { return false }
                    openConnections.insert(connection)
                    return true
                }
                guard allowed else { close(connection); return }
                DispatchQueue.global().async { [self] in receive(connection) }
            }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        lock.withLock {
            stopped = true
            for connection in openConnections { shutdown(connection, SHUT_RDWR) }
        }
    }

    func reply(content: String, index: Int = 0, status: Int = 200) {
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        sendResponse(body: body, index: index, status: status)
    }

    func sendResponse(body: Data, index: Int = 0, status: Int = 200, declaredLength: Int? = nil, finish: Bool = true) {
        let request = requests[index]
        let header = Data("HTTP/1.1 \(status) Controlled\r\nContent-Type: application/json\r\nContent-Length: \(declaredLength ?? body.count)\r\nConnection: close\r\n\r\n".utf8)
        sendBytes(header + body, to: request.connection)
        if finish { shutdown(request.connection, SHUT_WR) }
    }

    private func receive(_ connection: Int32) {
        defer { lock.withLock { openConnections.remove(connection); close(connection) } }
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?, expected = 0
        while bytes.count < 2 * 1_024 * 1_024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
               let header = String(data: bytes.prefix(end), encoding: .utf8) {
                headerEnd = end
                let lines = header.components(separatedBy: "\r\n")
                expected = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap {
                    Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                } ?? 0
            }
            if let headerEnd, bytes.count - headerEnd >= expected { break }
        }
        guard let headerEnd, let header = String(data: bytes.prefix(headerEnd), encoding: .utf8) else { return }
        let lines = header.components(separatedBy: "\r\n")
        let authorization = lines.first(where: { $0.lowercased().hasPrefix("authorization:") }).map {
            String($0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces))
        }
        let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
        let body = Data(bytes.dropFirst(headerEnd).prefix(expected))
        lock.withLock { received.append(Request(path: path, authorization: authorization, body: body, connection: connection)) }
        while recv(connection, &buffer, buffer.count, 0) > 0 {}
        lock.withLock { disconnected += 1 }
    }

    private func sendBytes(_ data: Data, to connection: Int32) {
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < pointer.count {
                let count = send(connection, base.advanced(by: sent), pointer.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

private enum AudioCoachServerError: Error { case socket }


struct AudioCoachResponseCase: Sendable {
    let content: String
    var failure: CoachFailure? = nil
    var status: Int = 200
}

enum AudioCoachUnavailableInput: Sendable { case missing, unreadable, malformed, invalidRate }
enum AudioCoachInvalidation: Sendable { case disable, delete, cancel, stop }

private func classicCoachWAV(pcm: Data, sampleRate: UInt32) -> Data {
    var wave = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var bytes = value.littleEndian
        withUnsafeBytes(of: &bytes) { wave.append(contentsOf: $0) }
    }
    append(UInt32(pcm.count + 36))
    wave.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
    wave.append(Data("data".utf8)); append(UInt32(pcm.count)); wave.append(pcm)
    return wave
}
