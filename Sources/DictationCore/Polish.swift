import Foundation

public enum PolishFailure: String, Error, Codable, LocalizedError, Sendable {
    case missingConfiguration, invalidConfiguration, missingCredentials, credentialsUnavailable
    case authentication, quota, rateLimited, incompatible, emptyResult, invalidResult, responseTooLarge, resultTooLarge
    case networkUnavailable, transportSecurity, serviceUnavailable, timedOut, cancelled, attemptInFlight
    case storageFailure, interruptedRequest
    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "润色：尚未选择服务和模型，原转写保留并等待配置。"
        case .invalidConfiguration: "润色：配置无效，请检查服务、模型、提示词和 5–600 秒截止。"
        case .missingCredentials: "润色：所选服务需要 API 密钥，原转写保留并等待配置。"
        case .credentialsUnavailable: "润色：无法访问服务钥匙串，请恢复钥匙串访问。"
        case .authentication: "润色：服务拒绝凭据，请检查密钥后显式重试。"
        case .quota: "润色：服务配额不足，请处理配额后显式重试。"
        case .rateLimited: "润色：服务限流，请稍后显式重试。"
        case .incompatible: "润色：模型或端点未提供有效 Chat 接口，请检查所选角色能力。"
        case .emptyResult: "润色：未返回可用文本，原转写已保留。"
        case .invalidResult: "润色：返回文本或格式无效，原转写已保留。"
        case .responseTooLarge: "润色：响应超过 1 MiB，已取消请求。"
        case .resultTooLarge: "润色：文本超过 256 KiB，不能作为润色结果。"
        case .networkUnavailable: "润色：网络或本地服务连接失败，请检查地址、网络和局域网权限。"
        case .transportSecurity: "润色：系统传输安全限制了连接，请检查 HTTPS 或本地服务配置。"
        case .serviceUnavailable: "润色：服务请求失败，原转写已保留，请显式重试。"
        case .timedOut: "润色：整体请求截止已到，已取消实际网络任务。"
        case .cancelled: "润色：该次请求已取消。"
        case .attemptInFlight: "润色：该尝试已经发送，不能重复发送。"
        case .storageFailure: "润色：结果未能安全保存，不能下载或上屏；不会自动重发。"
        case .interruptedRequest: "润色：上次请求结果未确认，请显式处置，不会自动重发。"
        }
    }
}

public enum PolishStatus: String, Codable, Sendable {
    case waitingForConfiguration, inFlight, succeeded, failed, timedOut, cancelled, interrupted
}

public struct PolishRecord: Codable, Equatable, Sendable {
    public var status: PolishStatus
    public var attemptID: UUID?
    public var serviceID: UUID?
    public var model: String?
    public var failure: PolishFailure?
    public init(status: PolishStatus, attemptID: UUID? = nil, serviceID: UUID? = nil,
                model: String? = nil, failure: PolishFailure? = nil) {
        self.status = status; self.attemptID = attemptID; self.serviceID = serviceID; self.model = model; self.failure = failure
    }
}

public struct PolishCompletion: Sendable {
    public let attemptID: UUID
    public let result: Result<String, PolishFailure>
}

@MainActor
public final class PolishAttempt {
    public let id: UUID
    public let serviceID: UUID
    public let model: String
    public private(set) var deadline: TimeInterval = 0
    private let timeout: TimeInterval
    private let timing: any RequestTiming
    private let completed: @MainActor (PolishCompletion) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private var deadlineTask: Task<Void, Never>?
    private var terminal = false
    fileprivate init(id: UUID, serviceID: UUID, model: String, url: URL, key: String?, body: Data,
                     timeout: TimeInterval, configuration: URLSessionConfiguration, timing: any RequestTiming,
                     completed: @escaping @MainActor (PolishCompletion) -> Void) {
        self.id = id; self.serviceID = serviceID; self.model = model
        self.timeout = timeout; self.timing = timing; self.completed = completed
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 600
        let delegate = BoundedPolishResponse { [weak self] result in
            Task { @MainActor [weak self] in self?.receive(result) }
        }
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        task = session.dataTask(with: request)
    }
    fileprivate func start() {
        guard !terminal else { return }
        deadline = timing.instant + timeout
        deadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await timing.wait(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            complete(.failure(.timedOut), cancelNetwork: true)
        }
        task.resume()
    }
    public func cancel() { complete(.failure(.cancelled), cancelNetwork: true) }
    fileprivate func abandon() {
        terminal = true
        session.invalidateAndCancel()
    }
    private func receive(_ result: Result<String, PolishFailure>) {
        guard !terminal else { return }
        if timing.instant >= deadline { complete(.failure(.timedOut), cancelNetwork: true) }
        else { complete(result, cancelNetwork: false) }
    }
    private func complete(_ result: Result<String, PolishFailure>, cancelNetwork: Bool) {
        guard !terminal else { return }
        terminal = true
        deadlineTask?.cancel()
        deadlineTask = nil
        if cancelNetwork { task.cancel(); session.invalidateAndCancel() }
        else { session.finishTasksAndInvalidate() }
        completed(PolishCompletion(attemptID: id, result: result))
    }
}

public enum PolishReadiness: Equatable, Sendable { case disabled, waiting(PolishFailure), ready }

@MainActor
public enum PolishDispatch {
    case disabled, waiting(PolishFailure), started(PolishAttempt)
}

@MainActor
public final class PolishClient {
    private let settings: PolishSettings
    private let services: ServiceSettings
    private let credentials: any ServiceCredentialStoring
    private let networkConfiguration: URLSessionConfiguration
    private let timing: any RequestTiming
    private var active: [UUID: PolishAttempt] = [:]
    public init(settings: PolishSettings, services: ServiceSettings, credentials: any ServiceCredentialStoring,
                networkConfiguration: URLSessionConfiguration = .ephemeral, timing: any RequestTiming = ContinuousRequestTiming()) {
        self.settings = settings; self.services = services; self.credentials = credentials
        self.networkConfiguration = networkConfiguration; self.timing = timing
    }
    public var readiness: PolishReadiness {
        do { return try snapshot() == nil ? .disabled : .ready }
        catch let failure as PolishFailure { return .waiting(failure) }
        catch { return .waiting(.invalidConfiguration) }
    }
    public func dispatch(rawTranscription: String, attemptID: UUID = UUID(),
                         beforeSend: (PolishAttempt) throws -> Void = { _ in },
                         completed: @escaping @MainActor (PolishCompletion) -> Void) throws -> PolishDispatch {
        guard active[attemptID] == nil else { throw PolishFailure.attemptInFlight }
        let snapshot: Snapshot
        do {
            guard let current = try self.snapshot() else { return .disabled }
            snapshot = current
        } catch let failure as PolishFailure { return .waiting(failure) }
        catch { return .waiting(.invalidConfiguration) }
        guard !rawTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolishFailure.emptyResult }
        guard rawTranscription.utf8.count <= 256 * 1024 else { throw PolishFailure.resultTooLarge }
        guard !rawTranscription.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }) else {
            throw PolishFailure.invalidResult
        }
        let body = try JSONEncoder().encode(ChatRequest(model: snapshot.role.model, messages: [
            .init(role: "system", content: snapshot.configuration.prompt), .init(role: "user", content: rawTranscription)
        ]))
        let attempt = PolishAttempt(id: attemptID, serviceID: snapshot.service.id, model: snapshot.role.model,
                                    url: snapshot.url, key: snapshot.key, body: body, timeout: snapshot.configuration.timeout,
                                    configuration: networkConfiguration, timing: timing) { [weak self] completion in
            self?.active[completion.attemptID] = nil
            completed(completion)
        }
        do { try beforeSend(attempt) } catch { attempt.abandon(); throw error }
        active[attemptID] = attempt
        attempt.start()
        return .started(attempt)
    }
    public func cancelAll() { Array(active.values).forEach { $0.cancel() } }
    private struct Snapshot {
        let configuration: PolishConfiguration
        let service: ModelService
        let role: ModelRoleConfiguration
        let url: URL
        let key: String?
    }
    private func snapshot() throws -> Snapshot? {
        let configuration: PolishConfiguration
        do { configuration = try settings.load() } catch { throw PolishFailure.invalidConfiguration }
        guard configuration.enabled else { return nil }
        guard let role = configuration.role else { throw PolishFailure.missingConfiguration }
        let registry: ModelConfiguration
        do { registry = try services.load() } catch { throw PolishFailure.invalidConfiguration }
        guard let service = registry.services.first(where: { $0.id == role.serviceID }) else { throw PolishFailure.missingConfiguration }
        guard let baseURL = URL(string: service.baseURL) else { throw PolishFailure.invalidConfiguration }
        var key: String?
        if service.authentication == .bearerToken {
            do { key = try credentials.key(for: service.credentialID ?? service.id) }
            catch { throw PolishFailure.credentialsUnavailable }
            guard let value = key, !value.isEmpty else { throw PolishFailure.missingCredentials }
            guard value.utf8.count <= 8192, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PolishFailure.invalidConfiguration
            }
        }
        return Snapshot(configuration: configuration, service: service, role: role,
                        url: baseURL.appendingPathComponent("chat/completions"), key: key)
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
}

private final class BoundedPolishResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var body = Data()
    private var failure: PolishFailure?
    private var status = 0
    private let completed: @Sendable (Result<String, PolishFailure>) -> Void
    private let limit = 1024 * 1024
    init(completed: @escaping @Sendable (Result<String, PolishFailure>) -> Void) { self.completed = completed }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { failure = .incompatible; completionHandler(.cancel); return }
        status = response.statusCode
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
        // 重定向不能将原转写和凭据改发至用户未选择的地址。
        failure = .incompatible
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            failure = .authentication
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        if let failure {
            // 大小护栏中止正文后仍保留已知 HTTP 原因；未读完整的 429 不能推断配额。
            completed(.failure(failure == .responseTooLarge ? knownHTTPFailure() ?? failure : failure))
            return
        }
        if let error = error as? URLError {
            let reason: PolishFailure = switch error.code {
            case .appTransportSecurityRequiresSecureConnection: .transportSecurity
            case .timedOut: .timedOut
            default: .networkUnavailable
            }
            completed(.failure(reason)); return
        }
        if status == 401 || status == 403 { completed(.failure(.authentication)); return }
        let validUTF8 = String(data: body, encoding: .utf8) != nil
        let object = validUTF8 ? (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] : nil
        if status == 429 {
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            completed(.failure(code == "insufficient_quota" ? .quota : .rateLimited)); return
        }
        guard (200...299).contains(status) else {
            completed(.failure([400, 404, 405, 415, 422].contains(status) ? .incompatible : .serviceUnavailable)); return
        }
        guard validUTF8, let object else { completed(.failure(.invalidResult)); return }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any], let text = message["content"] as? String else {
            completed(.failure(.incompatible)); return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completed(.failure(.emptyResult)); return }
        let incomplete = (first["finish_reason"] as? String).map { ["length", "content_filter"].contains($0) } ?? false
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }), !incomplete else {
            completed(.failure(.invalidResult)); return
        }
        guard text.utf8.count <= 256 * 1024 else { completed(.failure(.resultTooLarge)); return }
        completed(.success(text))
    }
    private func knownHTTPFailure() -> PolishFailure? {
        if status == 401 || status == 403 { return .authentication }
        if status == 429 { return .rateLimited }
        if [400, 404, 405, 415, 422].contains(status) { return .incompatible }
        return status > 0 && !(200...299).contains(status) ? .serviceUnavailable : nil
    }
}
