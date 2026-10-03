import Foundation

@MainActor
public final class CoachClient {
    private let settings: CoachSettings
    private let services: ServiceSettings
    private let credentials: any ServiceCredentialStoring
    private let networkConfiguration: URLSessionConfiguration
    private let timing: any RequestTiming
    var dispatchGate: ((ModelService) throws -> Void)?
    public init(settings: CoachSettings, services: ServiceSettings, credentials: any ServiceCredentialStoring,
                networkConfiguration: URLSessionConfiguration = .ephemeral, timing: any RequestTiming = ContinuousRequestTiming()) {
        self.settings = settings; self.services = services; self.credentials = credentials
        self.networkConfiguration = networkConfiguration; self.timing = timing
    }

    public func start(segmentID: UUID, attemptID: UUID = UUID(), rawText: String, originalAudio: Data? = nil,
                      willStart: (CoachDispatch) throws -> Void = { _ in },
                      completion: @escaping @MainActor (Result<CoachResult, CoachFailure>) -> Void) throws -> CoachRequest {
        try start(segmentID: segmentID, attemptID: attemptID, rawText: rawText,
                  audioForSegment: { _ in originalAudio }, willStart: willStart, completion: completion)
    }

    func start(segmentID: UUID, attemptID: UUID, rawText: String,
               audioForSegment: (UUID) throws -> Data?, willStart: (CoachDispatch) throws -> Void,
               completion: @escaping @MainActor (Result<CoachResult, CoachFailure>) -> Void) throws -> CoachRequest {
        guard CoachSettings.validText(rawText, maximumBytes: 256 * 1_024) else { throw CoachFailure.inputTooLarge }
        let initial = try currentSelection()
        let startedAt = timing.instant
        var prepared: Result<Data?, CoachFailure>?
        var selection = initial
        if initial.configuration.inputMode == .originalAudio {
            do { prepared = .success(try audioForSegment(segmentID)) }
            catch { prepared = .failure((error as? CoachFailure) ?? .audioUnavailable) }
            // 原音频 provider 可同步改配置；仅在它返回后确定实际派发的服务和输入方式。
            selection = try currentSelection()
        }
        let configuration = selection.configuration, role = selection.role
        let deadline = startedAt + configuration.timeout
        let wave = configuration.inputMode == .originalAudio ? try prepared?.get() : nil
        let payload = try PreparedCoachRequest(rawText: rawText, model: role.model, prompt: configuration.prompt,
            inputMode: configuration.inputMode, wave: wave)
        return try send(selection, payload: payload, identity: CoachWorkIdentity(segmentID: segmentID, attemptID: attemptID),
            rawText: rawText, deadline: deadline, willStart: willStart, completion: completion)
    }

    func startPrepared(segmentID: UUID, attemptID: UUID, rawText: String, payload: PreparedCoachRequest,
                       preparationElapsed: TimeInterval, willStart: (CoachDispatch) throws -> Void,
                       completion: @escaping @MainActor (Result<CoachResult, CoachFailure>) -> Void) throws -> CoachRequest {
        let selection = try currentSelection()
        guard payload.model == selection.role.model, payload.prompt == selection.configuration.prompt,
              payload.inputMode == selection.configuration.inputMode else { throw PreparationChanged() }
        return try send(selection, payload: payload, identity: CoachWorkIdentity(segmentID: segmentID, attemptID: attemptID),
            rawText: rawText, deadline: timing.instant + selection.configuration.timeout - preparationElapsed,
            willStart: willStart, completion: completion)
    }

    struct PreparationChanged: Error {}

    private func send(_ selection: Selection, payload: PreparedCoachRequest, identity: CoachWorkIdentity, rawText: String,
                      deadline: TimeInterval, willStart: (CoachDispatch) throws -> Void,
                      completion: @escaping @MainActor (Result<CoachResult, CoachFailure>) -> Void) throws -> CoachRequest {
        let configuration = selection.configuration, role = selection.role, service = selection.service, audio = payload.audio
        let dispatch = CoachDispatch(identity: identity, serviceID: service.id, model: role.model,
                                     prompt: configuration.prompt, timeout: configuration.timeout,
                                     audioUsed: audio != nil, audioFormat: audio?.format, audioDuration: audio?.duration)
        guard timing.instant < deadline else { throw CoachFailure.timedOut }
        var request = URLRequest(url: selection.url.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.httpBody = payload.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = selection.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        try willStart(dispatch)
        try dispatchGate?(service)
        guard timing.instant < deadline else { throw CoachFailure.timedOut }
        let handle = CoachRequest(dispatch: dispatch, service: service, request: request, rawText: rawText,
                                  deadline: deadline, networkConfiguration: networkConfiguration, timing: timing, completion: completion)
        handle.start()
        return handle
    }

    struct Selection {
        let configuration: CoachConfiguration
        let role: ModelRoleConfiguration
        let service: ModelService
        let url: URL
        let key: String?
    }

    func currentSelection() throws -> Selection {
        let configuration = try settings.load()
        guard configuration.enabled else { throw CoachFailure.disabled }
        let registry: ModelConfiguration
        do { registry = try services.load() } catch { throw CoachFailure.invalidConfiguration }
        guard let role = configuration.role, let service = registry.services.first(where: { $0.id == role.serviceID }),
              let url = URL(string: service.baseURL) else { throw CoachFailure.missingConfiguration }
        try dispatchGate?(service)
        var key: String?
        if service.authentication == .bearerToken {
            do { key = try credentials.key(for: service.credentialID ?? service.id) }
            catch { throw CoachFailure.credentialsUnavailable }
            guard let key, !key.isEmpty, key.utf8.count <= 8_192, !key.contains("\r"), !key.contains("\n") else {
                throw CoachFailure.missingCredentials
            }
        }
        return Selection(configuration: configuration, role: role, service: service, url: url, key: key)
    }

}

@MainActor
public final class CoachRequest {
    public let dispatch: CoachDispatch
    let service: ModelService
    private(set) var retryAfter: RetryAfter?
    public var identity: CoachWorkIdentity { dispatch.identity }
    public private(set) var deadline: TimeInterval = 0
    private let timing: any RequestTiming
    private let completion: @MainActor (Result<CoachResult, CoachFailure>) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private var deadlineTask: Task<Void, Never>?
    private var finished = false

    fileprivate init(dispatch: CoachDispatch, service: ModelService, request: URLRequest, rawText: String, deadline: TimeInterval,
                     networkConfiguration: URLSessionConfiguration, timing: any RequestTiming,
                     completion: @escaping @MainActor (Result<CoachResult, CoachFailure>) -> Void) {
        self.dispatch = dispatch; self.service = service; self.timing = timing; self.completion = completion; self.deadline = deadline
        let configuration = networkConfiguration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 600; configuration.timeoutIntervalForResource = 600
        let delegate = CoachResponse(rawText: rawText, audioDuration: dispatch.audioUsed ? dispatch.audioDuration : nil) { [weak self] result, retryAfter in
            Task { @MainActor in self?.receive(result, retryAfter: retryAfter) }
        }
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.dataTask(with: request)
    }

    fileprivate func start() {
        let timing = self.timing, deadline = self.deadline
        deadlineTask = Task { [weak self] in
            do { try await timing.wait(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.receive(.failure(.timedOut))
        }
        task.resume()
    }

    public func cancel() {
        guard !finished else { return }
        finish(.failure(.cancelled), cancelTransport: true)
    }

    public func cancelForDisabled() {
        guard !finished else { return }
        // 已经到达但尚未回到主线程的有效响应仍可入历史；原截止继续约束它。
        task.cancel(); session.invalidateAndCancel()
    }

    private func receive(_ result: Result<CoachResult, CoachFailure>, retryAfter: RetryAfter? = nil) {
        guard !finished else { return }
        if timing.instant >= deadline { finish(.failure(.timedOut), cancelTransport: true); return }
        if case .failure(.cancelled) = result { self.retryAfter = nil }
        else { self.retryAfter = retryAfter }
        finish(result, cancelTransport: false)
    }

    private func finish(_ result: Result<CoachResult, CoachFailure>, cancelTransport: Bool) {
        finished = true; deadlineTask?.cancel(); deadlineTask = nil
        if cancelTransport { task.cancel(); session.invalidateAndCancel() }
        else { session.finishTasksAndInvalidate() }
        completion(result)
    }
}

private final class CoachResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let rawText: String
    private let audioDuration: TimeInterval?
    private let onCompleted: @Sendable (Result<CoachResult, CoachFailure>, RetryAfter?) -> Void
    private var retryAfter: RetryAfter?
    private var body = Data()
    private var status = 0
    private var failure: CoachFailure?
    private let limit = 1_024 * 1_024
    init(rawText: String, audioDuration: TimeInterval?, completed: @escaping @Sendable (Result<CoachResult, CoachFailure>, RetryAfter?) -> Void) {
        self.rawText = rawText; self.audioDuration = audioDuration; self.onCompleted = completed
    }
    private func completed(_ result: Result<CoachResult, CoachFailure>) { onCompleted(result, retryAfter) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { failure = .incompatible; completionHandler(.cancel); return }
        status = response.statusCode
        retryAfter = RetryAfter.from(response)
        guard response.expectedContentLength <= limit else { failure = .responseTooLarge; completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= limit - body.count else { failure = .responseTooLarge; dataTask.cancel(); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = .incompatible; completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { failure = .authentication; completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        if let failure { completed(.failure(failure)); return }
        if let error = error as? URLError {
            let failure: CoachFailure = switch error.code {
            case .cancelled: .cancelled
            case .timedOut: .timedOut
            case .appTransportSecurityRequiresSecureConnection: .transportSecurity
            default: .networkUnavailable
            }
            completed(.failure(failure)); return
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if [401, 403].contains(status) { completed(.failure(.authentication)); return }
        if status == 429 {
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            completed(.failure(code == "insufficient_quota" ? .quota : .rateLimited)); return
        }
        guard (200...299).contains(status) else {
            completed(.failure([400, 404, 405, 415, 422].contains(status) ? (audioDuration == nil ? .incompatible : .audioIncompatible) : .serviceUnavailable)); return
        }
        guard let choices = object?["choices"] as? [[String: Any]], choices.count == 1,
              let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String else {
            completed(.failure(audioDuration == nil ? .incompatible : .audioIncompatible)); return
        }
        do { completed(.success(try CoachResult.validate(content: content, rawText: rawText, audioDuration: audioDuration))) }
        catch { completed(.failure(.invalidResult)) }
    }
}
