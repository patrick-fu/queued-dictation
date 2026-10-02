import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite(.serialized)
struct CoachBehaviorTests {
    @Test
    func aTextCoachSendsOnlyRawTextAndTheCurrentPromptToTheSelectedSharedService() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.customPrompt = "只根据这段原话给出有依据的英语建议；输出约定 JSON。"
        try fixture.settings.save(configuration)
        let segmentID = UUID(), attemptID = UUID()
        var result: Result<CoachResult, CoachFailure>?
        let request = try fixture.client.start(segmentID: segmentID, attemptID: attemptID,
                                              rawText: "I goes to work.") { result = $0 }
        defer { request.cancel() }
        try await waitUntil { server.requests.count == 1 }
        let received = try #require(server.requests.first)
        #expect(received.path == "/v1/chat/completions")
        #expect(received.authorization == "Bearer fake-coach-key")
        let json = try #require(try JSONSerialization.jsonObject(with: received.body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "messages", "stream"])
        #expect(json["model"] as? String == "fixture-coach")
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": configuration.prompt],
                             ["role": "user", "content": "I goes to work."]])
        server.reply(content: coachCardJSON)
        try await waitUntil { result != nil }
        let value = try #require(result).get()
        guard case .card(let feedback) = value else { Issue.record("应返回合法带教卡片"); return }
        #expect(feedback.suggestions.count == 1)
        #expect(feedback.suggestions[0].original == "I goes")
        #expect(feedback.suggestions[0].improved == "I go")
        #expect(feedback.suggestions[0].reason == "第一人称单数一般现在时使用 go。")
        #expect(request.identity.segmentID == segmentID)
        #expect(request.identity.attemptID == attemptID)
    }

    @Test
    func cardsKeepArrivalOrderAndRemovingOneDoesNotInvalidateAnotherOrDeleteFeedback() throws {
        var panel = CoachPanelState(enabled: true)
        let first = CoachWorkIdentity(segmentID: UUID()), second = CoachWorkIdentity(segmentID: UUID())
        let beganFirst = panel.begin(first, rawText: "I goes to work.")
        let beganSecond = panel.begin(second, rawText: "I goes to work.")
        #expect(beganFirst && beganSecond)
        let result = try CoachResult.validate(content: coachCardJSON, rawText: "I goes to work.")
        let secondPresentation = panel.complete(second, result: result)
        let firstPresentation = panel.complete(first, result: result)
        #expect(secondPresentation == .presented)
        #expect(firstPresentation == .presented)
        #expect(panel.cards.map(\.identity) == [second, first])
        panel.removeCard(second.segmentID)
        #expect(panel.cards.map(\.identity) == [first])
        #expect(panel.enabled)
        let repeated = panel.complete(second, result: result)
        #expect(repeated == .ignored)
    }

    @Test
    func disablingAllowsAValidLateResultOnlyInHistoryButTimeoutAndDeletionIgnoreIt() throws {
        var panel = CoachPanelState(enabled: true)
        let disabled = CoachWorkIdentity(segmentID: UUID()), timedOut = CoachWorkIdentity(segmentID: UUID())
        let deleted = CoachWorkIdentity(segmentID: UUID())
        for identity in [disabled, timedOut, deleted] {
            let began = panel.begin(identity, rawText: "I goes to work.")
            #expect(began)
        }
        panel.setEnabled(false)
        panel.invalidate(timedOut)
        panel.removeSegment(deleted.segmentID)
        panel.setEnabled(true)
        let result = try CoachResult.validate(content: coachCardJSON, rawText: "I goes to work.")
        let disabledPresentation = panel.complete(disabled, result: result)
        let timedOutPresentation = panel.complete(timedOut, result: result)
        let deletedPresentation = panel.complete(deleted, result: result)
        #expect(disabledPresentation == .historyOnly)
        #expect(timedOutPresentation == .ignored)
        #expect(deletedPresentation == .ignored)
        #expect(panel.cards.isEmpty)
        let fresh = CoachWorkIdentity(segmentID: UUID())
        let beganFresh = panel.begin(fresh, rawText: "I goes to work.")
        let freshPresentation = panel.complete(fresh, result: result)
        #expect(beganFresh)
        #expect(freshPresentation == .presented)
        #expect(panel.cards.map(\.identity) == [fresh])
    }

    @Test
    func theDeadlineCancelsARealConnectionEvenAfterTheResponseHeadersAndPartialBodyArrive() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var result: Result<CoachResult, CoachFailure>?
        let request = try fixture.client.start(segmentID: UUID(), rawText: "I goes to work.") { result = $0 }
        defer { request.cancel() }
        try await waitUntil { server.requests.count == 1 }
        server.sendResponse(body: Data(#"{"choices":[{"message":{"content":""#.utf8), declaredLength: 400, finish: false)
        fixture.timing.advance(to: 30)
        try await waitUntil { result != nil && server.disconnectCount == 1 }
        #expect(result == .failure(.timedOut))
        #expect(server.requests.count == 1)
    }

    @Test
    func theIndependentPoolUsesLatestSettingsAtDispatchAndPresentsFeedbackInArrivalOrder() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        let segmentIDs = (0..<4).map { _ in UUID() }
        for (index, id) in segmentIDs.enumerated() {
            try scheduler.enqueue(segmentID: id, rawText: "I goes to work. Segment \(index).")
        }
        try await waitUntil { server.requests.count == 3 }
        #expect(scheduler.inFlightCount == 3)
        #expect(scheduler.pendingCount == 1)
        var role = try fixture.settings.load()
        role.role = ModelRoleConfiguration(serviceID: fixture.serviceID, model: "changed-coach")
        role.customPrompt = "修改后完整提示词。"
        try fixture.settings.save(role)
        let credentialID = UUID()
        try fixture.services.save(ModelConfiguration(services: [ModelService(id: fixture.serviceID, name: "修改服务",
            baseURL: server.baseURL + "/changed", authentication: .bearerToken, credentialID: credentialID)]))
        try fixture.credentials.saveKey("fake-new-dispatch-key", for: credentialID)
        server.reply(content: coachCardJSON, index: 1)
        try await waitUntil { server.requests.count == 4 && scheduler.panelState.cards.count == 1 }
        let fourth = server.requests[3]
        #expect(fourth.path == "/changed/chat/completions")
        #expect(fourth.authorization == "Bearer fake-new-dispatch-key")
        let body = try #require(try JSONSerialization.jsonObject(with: fourth.body) as? [String: Any])
        #expect(body["model"] as? String == "changed-coach")
        #expect((body["messages"] as? [[String: String]])?.first?["content"] == "修改后完整提示词。")
        server.reply(content: coachCardJSON, index: 0)
        try await waitUntil { scheduler.panelState.cards.count == 2 }
        let firstRaw = try #require(try JSONSerialization.jsonObject(with: server.requests[1].body) as? [String: Any])["messages"] as? [[String: String]]
        #expect(scheduler.panelState.cards.first?.rawText == firstRaw?.last?["content"])
        #expect(updates.filter { $0.status == .succeeded }.count == 2)
        #expect(updates.filter { $0.status == .inFlight }.last?.dispatch?.model == "changed-coach")
    }

    @Test
    func plainChineseIsSkippedWhileMixedOrUncertainTextReachesTheSameCoachModel() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: { _ in })
        defer { scheduler.stopProcessing() }
        let plain = try scheduler.enqueue(segmentID: UUID(), rawText: "今天讨论上线时间，下午三点开会。")
        let empty = try scheduler.enqueue(segmentID: UUID(), rawText: " \n ")
        let cancelled = try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.", cancelled: true)
        let mixed = try scheduler.enqueue(segmentID: UUID(), rawText: "今天说 I goes to work. 然后继续。")
        #expect(!plain)
        #expect(!empty && !cancelled)
        #expect(mixed)
        try await waitUntil { server.requests.count >= 1 }
        #expect(server.requests.count == 1)
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests[0].body) as? [String: Any])
        #expect((body["messages"] as? [[String: String]])?.last?["content"] == "今天说 I goes to work. 然后继续。")
        let uncertain = try scheduler.enqueue(segmentID: UUID(), rawText: "中文夹 é。")
        #expect(uncertain)
        try await waitUntil { server.requests.count == 2 }
        let uncertainBody = try #require(try JSONSerialization.jsonObject(with: server.requests[1].body) as? [String: Any])
        #expect((uncertainBody["messages"] as? [[String: String]])?.last?["content"] == "中文夹 é。")
    }

    @Test(arguments: [
        CoachResponseCase(content: #"{"kind":"no_card"}"#, failure: nil),
        CoachResponseCase(content: #"{"kind":"card","suggestions":[]}"#, failure: .invalidResult),
        CoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"grammar","original":"I goes","improved":"I go","reason":"主谓一致。"},{"category":"grammar","original":"I goes","improved":"I go","reason":"主谓一致。"},{"category":"grammar","original":"I goes","improved":"I go","reason":"主谓一致。"}]}"#, failure: .invalidResult),
        CoachResponseCase(content: #"{"kind":"no_card","score":80}"#, failure: .invalidResult),
        CoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"fluency","original":"I goes","improved":"I go","reason":"停顿缩短。"}]}"#, failure: .invalidResult),
        CoachResponseCase(content: #"{"kind":"card","suggestions":[{"category":"grammar","original":"You goes","improved":"You go","reason":"主谓一致。"}]}"#, failure: .invalidResult),
        CoachResponseCase(content: "```json\n{\"kind\":\"no_card\"}\n```", failure: .invalidResult),
        CoachResponseCase(content: "provider error contains fake-secret-and-private-raw", failure: .authentication, status: 401),
        CoachResponseCase(content: "unsupported", failure: .incompatible, status: 404)
    ])
    func noCardAndMalformedOrFailedResultsAreDistinctAndNeverTriggerARepairRequest(_ sample: CoachResponseCase) async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        server.reply(content: sample.content, status: sample.status)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(scheduler.panelState.cards.isEmpty)
        if let failure = sample.failure {
            #expect(updates.last?.status == .failed)
            #expect(updates.last?.failure == failure)
            #expect(updates.last?.result == nil)
            #expect(scheduler.latestFailure?.localizedDescription.contains("fake-secret-and-private-raw") == false)
        } else {
            #expect(updates.last?.status == .succeeded)
            #expect(updates.last?.result == .noCard)
            #expect(updates.last?.failure == nil)
        }
        try scheduler.configurationChanged()
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [CoachWorkStatus.inFlight, .succeeded])
    func failureToPersistAnAttemptOrFeedbackNeverSendsUnsavedWorkOrPresentsAnUnsavedCard(_ rejected: CoachWorkStatus) async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: {
                if $0.status == rejected { throw CoachFailure.storageFailure }
                updates.append($0)
            })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        if rejected == .succeeded {
            try await waitUntil { server.requests.count == 1 }
            server.reply(content: coachCardJSON)
        }
        try await waitUntil { updates.last?.status == .failed }
        #expect(scheduler.latestFailure == .storageFailure)
        #expect(scheduler.panelState.cards.isEmpty)
        #expect(server.requests.count == (rejected == .inFlight ? 0 : 1))
        try scheduler.configurationChanged()
        #expect(scheduler.pendingCount == 0)
        #expect(server.requests.count == (rejected == .inFlight ? 0 : 1))
    }

    @Test
    func turningOffCancelsRealInFlightWorkAndNeverResumesOldPendingTextAfterReopening() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.concurrency = 1
        try fixture.settings.save(configuration)
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        let current = UUID(), queued = UUID()
        try scheduler.enqueue(segmentID: current, rawText: "I goes to work.")
        try scheduler.enqueue(segmentID: queued, rawText: "I goes to work. old pending.")
        try await waitUntil { server.requests.count == 1 }
        try scheduler.setEnabled(false)
        #expect(scheduler.pendingCount == 0)
        #expect(updates.contains { $0.identity.segmentID == queued && $0.status == .cancelled })
        try await waitUntil { scheduler.inFlightCount == 0 && server.disconnectCount == 1 }
        try scheduler.setEnabled(true)
        #expect(server.requests.count == 1)
        #expect(scheduler.panelState.cards.isEmpty)
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work. new segment.")
        try await waitUntil { server.requests.count == 2 }
        let json = try #require(try JSONSerialization.jsonObject(with: server.requests[1].body) as? [String: Any])
        #expect((json["messages"] as? [[String: String]])?.last?["content"] == "I goes to work. new segment.")
    }

    @Test
    func pausedWorkReadsNoCredentialsAndStartsItsDeadlineOnlyWhenTheExternalWindowAllowsDispatch() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var allowed = false
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, canDispatch: { _ in allowed }, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        #expect(updates.last?.status == .waitingForResume)
        #expect(fixture.credentials.reads == 0)
        fixture.timing.advance(to: 1_000)
        allowed = true
        try scheduler.configurationChanged()
        try await waitUntil { server.requests.count == 1 }
        #expect(fixture.credentials.reads == 1)
        server.reply(content: #"{"kind":"no_card"}"#)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(updates.last?.status == .succeeded)
        #expect(updates.last?.failure == nil)
    }

    @Test
    func deletingInFlightWorkActuallyCancelsItAndNeverEmitsAnUpdateThatCouldRecreateHistory() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        let id = UUID()
        try scheduler.enqueue(segmentID: id, rawText: "I goes to work.")
        try await waitUntil { server.requests.count == 1 }
        let beforeDeletion = updates
        scheduler.removeSegment(id)
        try await waitUntil { server.disconnectCount == 1 }
        #expect(updates == beforeDeletion)
        #expect(scheduler.inFlightCount == 0)
        #expect(scheduler.panelState.cards.isEmpty)
    }

    @Test
    func customPromptsSurviveReopeningAndDefaultsAreRestoredOnlyExplicitly() throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        let missing = CoachSettings(file: fixture.root.appendingPathComponent("absent.json"))
        let defaults = try missing.load()
        #expect(!defaults.enabled && defaults.concurrency == 3 && defaults.timeout == 30 && defaults.corner == .bottomRight)
        var configuration = try fixture.settings.load()
        configuration.customPrompt = "我自己的完整提示词，升级时应保留。"
        try fixture.settings.save(configuration)
        let reopened = CoachSettings(file: fixture.root.appendingPathComponent("coach.json"))
        #expect(try reopened.load().prompt == "我自己的完整提示词，升级时应保留。")
        try reopened.restoreDefaultPrompt()
        #expect(try reopened.load().customPrompt == nil)
        #expect(try reopened.load().prompt == CoachConfiguration.defaultPrompt)
        var invalid = try reopened.load()
        invalid.timeout = 601
        #expect(throws: CoachFailure.invalidConfiguration) { try reopened.save(invalid) }
        #expect(try reopened.load().timeout == 30)
        invalid = try reopened.load(); invalid.concurrency = 0
        #expect(throws: CoachFailure.invalidConfiguration) { try reopened.save(invalid) }
        let ordinaryConfiguration = try String(contentsOf: fixture.root.appendingPathComponent("coach.json"), encoding: .utf8)
        #expect(!ordinaryConfiguration.contains("fake-coach-key"))
        #expect(!ordinaryConfiguration.contains("I goes to work."))
    }

    @Test
    func missingRoleWaitsWithoutReadingCredentialsAndRepairUsesTheLatestSharedCredentialReference() async throws {
        let server = try CoachLoopbackServer()
        defer { server.stop() }
        let fixture = try CoachFixture(server: server)
        defer { fixture.remove() }
        var configuration = try fixture.settings.load()
        configuration.role = nil
        try fixture.settings.save(configuration)
        var updates: [CoachWorkUpdate] = []
        let scheduler = try CoachWorkScheduler(settings: fixture.settings, services: fixture.services,
            credentials: fixture.credentials, timing: fixture.timing, onUpdate: { updates.append($0) })
        defer { scheduler.stopProcessing() }
        try scheduler.enqueue(segmentID: UUID(), rawText: "I goes to work.")
        #expect(updates.last?.status == .waitingForConfiguration)
        #expect(updates.last?.failure == .missingConfiguration)
        #expect(fixture.credentials.reads == 0)
        configuration.role = ModelRoleConfiguration(serviceID: fixture.serviceID, model: "repaired-coach")
        try fixture.settings.save(configuration)
        try fixture.credentials.saveKey(nil, for: fixture.serviceID)
        try scheduler.configurationChanged()
        #expect(updates.last?.failure == .missingCredentials)
        fixture.timing.advance(to: 1_000)
        let keyID = UUID()
        try fixture.credentials.saveKey("fake-repaired-key", for: keyID)
        try fixture.services.save(ModelConfiguration(services: [ModelService(id: fixture.serviceID, name: "修复后的服务",
            baseURL: server.baseURL + "/repaired", authentication: .bearerToken, credentialID: keyID)]))
        configuration.role = ModelRoleConfiguration(serviceID: fixture.serviceID, model: "repaired-coach")
        try fixture.settings.save(configuration)
        try scheduler.configurationChanged()
        try await waitUntil { server.requests.count == 1 }
        #expect(server.requests[0].authorization == "Bearer fake-repaired-key")
        #expect(server.requests[0].path == "/repaired/chat/completions")
        server.reply(content: #"{"kind":"no_card"}"#)
        try await waitUntil { scheduler.inFlightCount == 0 }
        #expect(updates.last?.status == .succeeded)
    }
}

private let coachCardJSON = #"{"kind":"card","suggestions":[{"category":"grammar","original":"I goes","improved":"I go","reason":"第一人称单数一般现在时使用 go。"}]}"#

@MainActor
private final class CoachFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let services: ServiceSettings
    let settings: CoachSettings
    let credentials = CoachTestCredentials()
    let timing = ControlledRequestTiming()
    let serviceID = UUID()
    let client: CoachClient
    init(server: CoachLoopbackServer) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        settings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        client = CoachClient(settings: settings, services: services, credentials: credentials, timing: timing)
        try services.save(ModelConfiguration(services: [
            ModelService(id: serviceID, name: "受控带教服务", baseURL: server.baseURL + "/v1", authentication: .bearerToken)
        ]))
        try credentials.saveKey("fake-coach-key", for: serviceID)
        try settings.save(CoachConfiguration(enabled: true, role: ModelRoleConfiguration(serviceID: serviceID, model: "fixture-coach")))
    }
    func remove() { timing.cancelAll(); try? FileManager.default.removeItem(at: root) }
}

private final class CoachLoopbackServer: @unchecked Sendable {
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
        guard descriptor >= 0 else { throw CoachServerError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { close(listener); throw CoachServerError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(listener); throw CoachServerError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "coach-test-loopback").async { [self] in
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

private enum CoachServerError: Error { case socket }

struct CoachResponseCase: Sendable {
    let content: String
    let failure: CoachFailure?
    var status = 200
}

@MainActor
private final class CoachTestCredentials: ServiceCredentialStoring {
    private var keys: [UUID: String] = [:]
    private(set) var reads = 0
    func key(for serviceID: UUID) throws -> String? { reads += 1; return keys[serviceID] }
    func saveKey(_ key: String?, for serviceID: UUID) throws { keys[serviceID] = key }
}
