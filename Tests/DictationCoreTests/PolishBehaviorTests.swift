import Darwin
import Foundation
import Testing
@testable import DictationCore

@MainActor
@Suite
struct PolishBehaviorTests {
    @Test(arguments: [4.0, 601.0, Double.nan, Double.infinity])
    func invalidDeadlineSettingsPreserveThePreviouslySavedConfiguration(_ timeout: TimeInterval) throws {
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.settings.save(PolishConfiguration(enabled: true, timeout: 30, customPrompt: "自定义润色规则"))
        #expect(throws: PolishFailure.invalidConfiguration) {
            try fixture.settings.save(PolishConfiguration(enabled: true, timeout: timeout, customPrompt: "错误配置"))
        }
        #expect(try fixture.settings.load().timeout == 30)
        #expect(try fixture.settings.load().prompt == "自定义润色规则")
    }

    @Test
    func aPolishRequestSendsOnlyTheRawTranscriptAndCompletePromptToTheSelectedRole() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL + "/v1", key: "fake-polish-key",
                              prompt: "保留原意；删除重复词。\n只返回整理后的全文。")
        let attemptID = UUID()
        var completions: [PolishCompletion] = []
        let dispatched = try fixture.client.dispatch(rawTranscription: "嗯，我们我们明天发布。", attemptID: attemptID) { completions.append($0) }
        guard case .started(let attempt) = dispatched else { Issue.record("已配置润色应真实派发请求"); return }
        try await polishWait { server.requests.count == 1 }
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer fake-polish-key")
        let payload = try JSONDecoder().decode(PolishRequestPayload.self, from: request.body)
        #expect(payload.model == "fixture-polish")
        #expect(payload.messages == [PolishRequestPayload.Message(role: "system", content: "保留原意；删除重复词。\n只返回整理后的全文。"),
                                    PolishRequestPayload.Message(role: "user", content: "嗯，我们我们明天发布。")])
        let object = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(Set(object.keys) == ["model", "messages"])
        try server.reply(text: "我们明天发布。")
        try await polishWait { completions.count == 1 }
        #expect(attempt.id == attemptID)
        #expect(completions.first?.attemptID == attemptID)
        #expect(try completions.first?.result.get() == "我们明天发布。")
        #expect(server.requests.count == 1)
    }

    @Test
    func missingConfigurationWaitsAndRepairUsesTheLatestServiceModelKeyAndPrompt() async throws {
        let oldServer = try PolishLoopbackServer()
        let latestServer = try PolishLoopbackServer()
        defer { oldServer.stop(); latestServer.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        var completed: [PolishCompletion] = []
        #expect(fixture.client.readiness == .disabled)
        let disabled = try fixture.client.dispatch(rawTranscription: "配置前的原文。") { completed.append($0) }
        guard case .disabled = disabled else { Issue.record("润色默认关闭"); return }
        try fixture.settings.save(PolishConfiguration(enabled: true))
        #expect(fixture.client.readiness == .waiting(.missingConfiguration))
        let missingRole = try fixture.client.dispatch(rawTranscription: "等待配置的原文。") { completed.append($0) }
        guard case .waiting(.missingConfiguration) = missingRole else { Issue.record("缺角色时保持等待"); return }
        try fixture.configure(baseURL: oldServer.baseURL + "/old")
        #expect(fixture.client.readiness == .waiting(.missingCredentials))
        let missingKey = try fixture.client.dispatch(rawTranscription: "缺密钥仍保留的原文。") { completed.append($0) }
        guard case .waiting(.missingCredentials) = missingKey else { Issue.record("缺密钥时保持等待"); return }
        #expect(completed.isEmpty)
        #expect(oldServer.requests.isEmpty)
        let latestID = UUID()
        try fixture.services.save(ModelConfiguration(services: [ModelService(id: latestID, name: "最新服务",
            baseURL: latestServer.baseURL + "/new", authentication: .bearerToken)]))
        try fixture.credentials.saveKey("fake-latest-key", for: latestID)
        try fixture.settings.save(PolishConfiguration(enabled: true, role: .init(serviceID: latestID, model: "latest-polish"),
            timeout: 55, customPrompt: "最新完整提示词"))
        #expect(fixture.client.readiness == .ready)
        let dispatch = try fixture.client.dispatch(rawTranscription: "配置修复后的原文。") { completed.append($0) }
        guard case .started(let attempt) = dispatch else { Issue.record("修复后的新派发应成功"); return }
        try await polishWait { latestServer.requests.count == 1 }
        let request = try #require(latestServer.requests.first)
        let payload = try JSONDecoder().decode(PolishRequestPayload.self, from: request.body)
        #expect(request.path == "/new/chat/completions")
        #expect(request.headers["authorization"] == "Bearer fake-latest-key")
        #expect(payload.model == "latest-polish")
        #expect(payload.messages.first?.content == "最新完整提示词")
        #expect(attempt.serviceID == latestID)
        #expect(attempt.deadline == 55)
        try latestServer.reply(text: "采用最新配置。")
        try await polishWait { completed.count == 1 }
        #expect(try completed.first?.result.get() == "采用最新配置。")
        #expect(oldServer.requests.isEmpty)
    }

    @Test
    func changingSettingsLeavesTheInFlightSnapshotAndDoesNotAutomaticallyResendIt() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL + "/old", key: "fake-old-key", prompt: "旧提示词")
        var completed: [PolishCompletion] = []
        let firstID = UUID()
        let firstDispatch = try fixture.client.dispatch(rawTranscription: "第一个原始转写。", attemptID: firstID) { completed.append($0) }
        guard case .started(let first) = firstDispatch else { Issue.record("首次派发应成功"); return }
        try await polishWait { server.requests.count == 1 }
        try fixture.configure(baseURL: server.baseURL + "/new", key: "fake-new-key", model: "new-model",
                              prompt: "新提示词", timeout: 90)
        #expect(fixture.client.readiness == .ready)
        #expect(server.requests.count == 1)
        #expect(first.deadline == 30)
        #expect(throws: PolishFailure.attemptInFlight) {
            try fixture.client.dispatch(rawTranscription: "不得重发的原文。", attemptID: firstID) { completed.append($0) }
        }
        let second = try fixture.client.dispatch(rawTranscription: "第二个原始转写。") { completed.append($0) }
        guard case .started(let secondAttempt) = second else { Issue.record("新尝试应取新设置"); return }
        try await polishWait { server.requests.count == 2 }
        let oldRequest = server.requests[0]
        let newRequest = server.requests[1]
        #expect(oldRequest.path == "/old/chat/completions")
        #expect(oldRequest.headers["authorization"] == "Bearer fake-old-key")
        #expect(try JSONDecoder().decode(PolishRequestPayload.self, from: oldRequest.body).messages.first?.content == "旧提示词")
        #expect(newRequest.path == "/new/chat/completions")
        #expect(newRequest.headers["authorization"] == "Bearer fake-new-key")
        #expect(try JSONDecoder().decode(PolishRequestPayload.self, from: newRequest.body).model == "new-model")
        #expect(try JSONDecoder().decode(PolishRequestPayload.self, from: newRequest.body).messages.first?.content == "新提示词")
        #expect(secondAttempt.id != firstID)
        #expect(secondAttempt.deadline == 90)
        try server.reply(text: "第二个润色先完成。", index: 1)
        try server.reply(text: "第一个润色后完成。", index: 0)
        try await polishWait { completed.count == 2 }
        #expect(completed.map(\.attemptID).contains(firstID))
        #expect(server.requests.count == 2)
    }

    @Test
    func aServiceWithoutAuthenticationDoesNotReadOrSendAnOldCredential() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, key: "fake-unused-key", authentication: .none)
        var result: PolishCompletion?
        _ = try fixture.client.dispatch(rawTranscription: "无鉴权的本段原文。") { result = $0 }
        try await polishWait { server.requests.count == 1 }
        #expect(server.requests.first?.headers["authorization"] == nil)
        try server.reply(text: "本地服务的结果。")
        try await polishWait { result != nil }
        #expect(try result?.result.get() == "本地服务的结果。")
    }

    @Test
    func aSendingAttemptIsNotStartedWhenItsDurableBeforeSendStepFails() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, authentication: .none)
        var completed: [PolishCompletion] = []
        #expect(throws: PolishFailure.storageFailure) {
            try fixture.client.dispatch(rawTranscription: "必须先存储尝试。", beforeSend: { _ in throw PolishFailure.storageFailure }) { completed.append($0) }
        }
        #expect(server.requests.isEmpty)
        #expect(completed.isEmpty)
        #expect(fixture.client.readiness == .ready)
    }

    @Test
    func theCompleteDeadlineCancelsASlowRealHTTPBodyAndExplicitRetryHasANewIdentity() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, authentication: .none)
        var completed: [PolishCompletion] = []
        let oldID = UUID()
        _ = try fixture.client.dispatch(rawTranscription: "等待完整响应。", attemptID: oldID) { completed.append($0) }
        try await polishWait { server.requests.count == 1 }
        try server.sendHead(headers: ["Content-Length": "10000"])
        try server.sendBody(Data("{\"choices\":[{\"message\":{\"content\":\"尚未读完".utf8))
        fixture.timing.advance(to: 29)
        #expect(completed.isEmpty)
        fixture.timing.advance(to: 30)
        try await polishWait { completed.count == 1 && server.disconnections == 1 }
        #expect(completed.first?.attemptID == oldID)
        #expect(throws: PolishFailure.timedOut) { try completed.first?.result.get() }
        #expect(server.requests.count == 1)
        let retried = try fixture.client.dispatch(rawTranscription: "用户显式重试。") { completed.append($0) }
        guard case .started(let retry) = retried else { Issue.record("显式重试应派发"); return }
        try await polishWait { server.requests.count == 2 }
        #expect(retry.id != oldID)
        #expect(retry.deadline == 60)
        try server.reply(text: "新尝试的有效润色。", index: 1)
        try await polishWait { completed.count == 2 }
        #expect(try completed.last?.result.get() == "新尝试的有效润色。")
        #expect(completed.last?.attemptID == retry.id)
    }

    @Test
    func explicitCancellationClosesTheActualHTTPConnectionAndHasOneTerminalResult() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, authentication: .none)
        var completed: [PolishCompletion] = []
        let dispatch = try fixture.client.dispatch(rawTranscription: "待取消的本段原文。") { completed.append($0) }
        guard case .started(let attempt) = dispatch else { Issue.record("应有在途请求"); return }
        try await polishWait { server.requests.count == 1 }
        attempt.cancel()
        attempt.cancel()
        fixture.timing.advance(to: 30)
        try await polishWait { server.disconnections == 1 }
        #expect(completed.count == 1)
        #expect(throws: PolishFailure.cancelled) { try completed.first?.result.get() }
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [
        PolishFailureCase(status: 401, body: Data("fake-provider-secret".utf8), expected: .authentication),
        PolishFailureCase(status: 401, body: Data("{}".utf8), headers: ["WWW-Authenticate": "Basic realm=\"controlled\""], expected: .authentication),
        PolishFailureCase(status: 403, body: Data([0xff]), expected: .authentication),
        PolishFailureCase(status: 429, body: Data("{\"error\":{\"code\":\"insufficient_quota\"}}".utf8), expected: .quota),
        PolishFailureCase(status: 429, body: Data("{\"error\":{\"code\":\"rate_limit_exceeded\"}}".utf8), expected: .rateLimited),
        PolishFailureCase(status: 429, body: Data([0xff]), expected: .rateLimited),
        PolishFailureCase(status: 404, body: Data("not compatible".utf8), expected: .incompatible),
        PolishFailureCase(status: 404, body: Data([0xff]), expected: .incompatible),
        PolishFailureCase(status: 500, body: Data("unavailable".utf8), expected: .serviceUnavailable),
        PolishFailureCase(status: 200, body: Data("{\"text\":\"wrong role shape\"}".utf8), expected: .incompatible),
        PolishFailureCase(status: 200, body: Data("{\"choices\":[{\"message\":{\"content\":\" \\n \\t\"}}]}".utf8), expected: .emptyResult),
        PolishFailureCase(status: 200, body: Data("{\"choices\":[{\"message\":{\"content\":\"bad\\u0000text\"}}]}".utf8), expected: .invalidResult),
        PolishFailureCase(status: 200, body: Data("{\"choices\":[{\"message\":{\"content\":\"unfinished\"},\"finish_reason\":\"length\"}]}".utf8), expected: .invalidResult),
        PolishFailureCase(status: 200, body: Data("invalid JSON".utf8), expected: .invalidResult),
        PolishFailureCase(status: 200, body: Data([0xff]), expected: .invalidResult)
    ])
    func actualProtocolFailuresHaveRoleSpecificReasonsAndNeverExposeProviderBodiesOrResend(_ sample: PolishFailureCase) async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, key: "fake-polish-key")
        var completed: [PolishCompletion] = []
        _ = try fixture.client.dispatch(rawTranscription: "失败时仍保留的原始转写。") { completed.append($0) }
        try await polishWait { server.requests.count == 1 }
        try server.respond(status: sample.status, body: sample.body, headers: sample.headers)
        try await polishWait { completed.count == 1 }
        #expect(throws: sample.expected) { try completed.first?.result.get() }
        #expect(!sample.expected.localizedDescription.contains("fake-provider-secret"))
        #expect(!sample.expected.localizedDescription.contains("fake-polish-key"))
        #expect(fixture.client.readiness == .ready)
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [true, false])
    func responseBufferIsBoundedAndTheRealConnectionIsCancelled(_ declaresLength: Bool) async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, authentication: .none)
        var completed: [PolishCompletion] = []
        _ = try fixture.client.dispatch(rawTranscription: "有界响应。") { completed.append($0) }
        try await polishWait { server.requests.count == 1 }
        try server.sendHead(headers: declaresLength ? ["Content-Length": "1048577"] : [:])
        // 本机仅发头时未观察到终态；前缀远小于护栏，仍只靠声明长度拒绝。
        if declaresLength { try server.sendBody(Data(repeating: 0x41, count: 512)) }
        else { try? server.sendBody(Data(repeating: 0x41, count: 1024 * 1024 + 1)) }
        try await polishWait { completed.count == 1 }
        #expect(throws: PolishFailure.responseTooLarge) { try completed.first?.result.get() }
        try await polishWait { server.disconnections == 1 }
    }

    @Test
    func oversizedTextIsRejectedEvenInsideAValidBoundedChatResponse() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, authentication: .none)
        var completed: PolishCompletion?
        _ = try fixture.client.dispatch(rawTranscription: "拒绝超长文本。") { completed = $0 }
        try await polishWait { server.requests.count == 1 }
        try server.reply(text: String(repeating: "A", count: 256 * 1024 + 1))
        try await polishWait { completed != nil }
        #expect(throws: PolishFailure.resultTooLarge) { try completed?.result.get() }
    }

    @Test
    func customPromptSurvivesReopeningAndRestorePersistsTheCurrentDefaultChoice() throws {
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.settings.save(PolishConfiguration(enabled: true, customPrompt: "完整自定义指令\n保留我的文字"))
        let reopened = PolishSettings(file: fixture.root.appendingPathComponent("polish.json"))
        #expect(try reopened.load().prompt == "完整自定义指令\n保留我的文字")
        var configuration = try reopened.load()
        configuration.restoreDefaultPrompt()
        try reopened.save(configuration)
        #expect(try reopened.load().customPrompt == nil)
        #expect(try reopened.load().prompt == PolishConfiguration.defaultPrompt)
        #expect(try reopened.load().enabled)
    }

    @Test(arguments: [
        PolishServiceCommitCase(configurationFails: false, credentialsFail: false, cleanupFails: false,
                                expectedPath: "/new/chat/completions", expectedAuthorization: "Bearer fake-new-key"),
        PolishServiceCommitCase(configurationFails: true, credentialsFail: false, cleanupFails: false,
                                expectedPath: "/old/chat/completions", expectedAuthorization: "Bearer fake-old-key"),
        PolishServiceCommitCase(configurationFails: true, credentialsFail: false, cleanupFails: true,
                                expectedPath: "/old/chat/completions", expectedAuthorization: "Bearer fake-old-key"),
        PolishServiceCommitCase(configurationFails: false, credentialsFail: true, cleanupFails: false,
                                expectedPath: "/old/chat/completions", expectedAuthorization: "Bearer fake-old-key")
    ])
    func sharedServiceEditsKeepEndpointAndCredentialTogetherWithoutChangingTheTranscriptionRole(_ sample: PolishServiceCommitCase) async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL + "/old", key: "fake-old-key")
        var registry = try fixture.services.load()
        registry.transcription = ModelRoleConfiguration(serviceID: fixture.serviceID, model: "unchanged-asr-model")
        registry.transcriptionTimeout = 75
        try fixture.services.save(registry)
        fixture.credentials.rejectWrites = sample.credentialsFail
        fixture.credentials.rejectDeletion = sample.cleanupFails
        if sample.configurationFails { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path) }
        var rejected = false
        do {
            try fixture.services.saveService(ModelService(id: fixture.serviceID, name: "更新的共享服务", baseURL: server.baseURL + "/new", authentication: .bearerToken),
                                             newKey: "fake-new-key", credentials: fixture.credentials)
        } catch { rejected = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        fixture.credentials.rejectWrites = false
        fixture.credentials.rejectDeletion = false
        #expect(rejected == (sample.configurationFails || sample.credentialsFail))
        let reopenedServices = ServiceSettings(file: fixture.root.appendingPathComponent("services.json"))
        let reloaded = try reopenedServices.load()
        #expect(reloaded.transcription?.model == "unchanged-asr-model")
        #expect(reloaded.transcription?.serviceID == fixture.serviceID)
        #expect(reloaded.transcriptionTimeout == 75)
        let restarted = PolishClient(settings: fixture.settings, services: reopenedServices,
            credentials: fixture.credentials, timing: fixture.timing)
        defer { restarted.cancelAll() }
        var completion: PolishCompletion?
        _ = try restarted.dispatch(rawTranscription: "服务重开后的原转写。") { completion = $0 }
        try await polishWait { server.requests.count == 1 }
        #expect(server.requests.first?.path == sample.expectedPath)
        #expect(server.requests.first?.headers["authorization"] == sample.expectedAuthorization)
        try server.reply(text: "服务与凭据一致。")
        try await polishWait { completion != nil }
        #expect(try completion?.result.get() == "服务与凭据一致。")
        let ordinary = try String(contentsOf: fixture.root.appendingPathComponent("services.json"), encoding: .utf8)
        #expect(!ordinary.contains("fake-new-key"))
        #expect(!ordinary.contains("fake-old-key"))
    }

    @Test
    func aRealRedirectNeverSendsTheTranscriptOrBearerTokenToItsNewAddress() async throws {
        let source = try PolishLoopbackServer()
        let destination = try PolishLoopbackServer()
        defer { source.stop(); destination.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: source.baseURL + "/v1", key: "fake-nonredirectable-key")
        var completion: PolishCompletion?
        _ = try fixture.client.dispatch(rawTranscription: "不得重定向的原始转写。") { completion = $0 }
        try await polishWait { source.requests.count == 1 }
        try source.respond(status: 307, body: Data("redirect".utf8), headers: ["Location": destination.baseURL + "/chat/completions"])
        try await polishWait { completion != nil }
        #expect(throws: PolishFailure.incompatible) { try completion?.result.get() }
        #expect(destination.requests.isEmpty)
        #expect(source.requests.count == 1)
    }

    @Test
    func aValidBodyArrivingAtTheDeadlineCannotWinWhileTheTimerCallbackIsStillSuspended() async throws {
        let server = try PolishLoopbackServer()
        defer { server.stop() }
        let fixture = try PolishFixture()
        defer { fixture.remove() }
        try fixture.configure(baseURL: server.baseURL, authentication: .none)
        let clock = SuspendedPolishTiming()
        let client = PolishClient(settings: fixture.settings, services: fixture.services, credentials: fixture.credentials, timing: clock)
        defer { client.cancelAll() }
        var completed: [PolishCompletion] = []
        _ = try client.dispatch(rawTranscription: "到期结果不能接纳。") { completed.append($0) }
        try await polishWait { server.requests.count == 1 }
        clock.instant = 30
        try server.reply(text: "到期的完整有效响应。")
        try await polishWait { completed.count == 1 }
        #expect(throws: PolishFailure.timedOut) { try completed.first?.result.get() }
    }
}

@MainActor
private final class SuspendedPolishTiming: RequestTiming {
    var instant: TimeInterval = 0
    func wait(until deadline: TimeInterval) async throws { try await Task.sleep(for: .seconds(60)) }
}

struct PolishFailureCase: Sendable {
    let status: Int
    let body: Data
    var headers: [String: String] = [:]
    let expected: PolishFailure
}

struct PolishServiceCommitCase: Sendable {
    let configurationFails: Bool
    let credentialsFail: Bool
    let cleanupFails: Bool
    let expectedPath: String
    let expectedAuthorization: String
}

private struct PolishRequestPayload: Decodable {
    struct Message: Decodable, Equatable { let role: String; let content: String }
    let model: String
    let messages: [Message]
}

@MainActor
private final class PolishFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("polish-test-\(UUID())")
    let serviceID = UUID()
    let settings: PolishSettings
    let services: ServiceSettings
    let credentials = TestServiceCredentials()
    let timing = ControlledRequestTiming()
    let client: PolishClient
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = PolishSettings(file: root.appendingPathComponent("polish.json"))
        services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        client = PolishClient(settings: settings, services: services, credentials: credentials, timing: timing)
    }
    func configure(baseURL: String, key: String? = nil, model: String = "fixture-polish", prompt: String? = nil,
                   timeout: TimeInterval = 30, authentication: ServiceAuthentication = .bearerToken) throws {
        try services.save(ModelConfiguration(services: [ModelService(id: serviceID, name: "受控润色服务", baseURL: baseURL, authentication: authentication)]))
        if let key { try credentials.saveKey(key, for: serviceID) }
        try settings.save(PolishConfiguration(enabled: true, role: ModelRoleConfiguration(serviceID: serviceID, model: model),
                                             timeout: timeout, customPrompt: prompt))
    }
    func remove() { client.cancelAll(); timing.cancelAll(); try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func polishWait(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < end else { throw PolishTestError.waitExpired }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum PolishTestError: Error { case socket, requestMissing, waitExpired }

private final class PolishLoopbackServer: @unchecked Sendable {
    struct Request: Sendable { let path: String; let headers: [String: String]; let body: Data }
    private let lock = NSLock()
    private let listener: Int32
    private var received: [Request] = []
    private var connections: [Int32] = []
    private var ended: Set<Int> = []
    let baseURL: String
    var requests: [Request] { lock.withLock { received } }
    var disconnections: Int { lock.withLock { ended.count } }
    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw PolishTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { close(descriptor); throw PolishTestError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(descriptor); throw PolishTestError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "polish-test-accept").async { [self] in serve() }
    }
    func stop() {
        shutdown(listener, SHUT_RDWR)
        let open = lock.withLock { connections.enumerated().filter { !ended.contains($0.offset) }.map(\.element) }
        open.forEach { shutdown($0, SHUT_RDWR) }
    }
    func reply(text: String, index: Int = 0) throws {
        let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
        try respond(status: 200, body: body, index: index)
    }
    func respond(status: Int, body: Data, headers: [String: String] = [:], index: Int = 0) throws {
        try sendHead(status: status, headers: headers.merging(["Content-Length": String(body.count)]) { current, _ in current }, index: index)
        try sendBody(body, index: index)
    }
    func sendHead(status: Int = 200, headers: [String: String], index: Int = 0) throws {
        let fields = headers.merging(["Content-Type": "application/json", "Connection": "close"]) { current, _ in current }
        let head = "HTTP/1.1 \(status) Test\r\n" + fields.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        try sendBody(Data(head.utf8), index: index)
    }
    func sendBody(_ data: Data, index: Int = 0) throws {
        let connection = try lock.withLock {
            guard connections.indices.contains(index), !ended.contains(index) else { throw PolishTestError.requestMissing }
            return connections[index]
        }
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < pointer.count {
                let count = send(connection, base.advanced(by: sent), pointer.count - sent, 0)
                guard count > 0 else { throw PolishTestError.socket }
                sent += count
            }
        }
    }
    private func serve() {
        defer { close(listener) }
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue(label: "polish-test-connection").async { [self] in receive(connection) }
        }
    }
    private func receive(_ connection: Int32) {
        var requestIndex: Int?
        defer {
            if let requestIndex { lock.withLock { _ = ended.insert(requestIndex) } }
            close(connection)
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count <= 2 * 1024 * 1024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
                  let head = String(data: bytes.prefix(end), encoding: .utf8) else { continue }
            let lines = head.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let split = line.firstIndex(of: ":") {
                    headers[String(line[..<split]).lowercased()] = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            let expected = Int(headers["content-length"] ?? "0") ?? 0
            guard bytes.count - end >= expected else { continue }
            let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
            lock.withLock {
                requestIndex = connections.count
                received.append(Request(path: path, headers: headers, body: bytes.subdata(in: end..<(end + expected))))
                connections.append(connection)
            }
            while recv(connection, &buffer, buffer.count, 0) > 0 {}
            return
        }
    }
}
