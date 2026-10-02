import Foundation

public enum TranscriptionStatus: String, Codable, Sendable {
    case waitingForSlot, waitingForConfiguration, inFlight, succeeded, failed, timedOut, cancelled, interrupted
}

public enum TranscriptionFailure: String, Error, Codable, LocalizedError, Sendable {
    case missingConfiguration, invalidConfiguration, missingCredentials, credentialsUnavailable
    case authentication, quota, rateLimited, incompatible, emptyResult, responseTooLarge, resultTooLarge
    case networkUnavailable, transportSecurity, serviceUnavailable, timedOut, storageFailure, interruptedRequest
    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "转写：尚未配置服务和模型，音频已保留。"
        case .invalidConfiguration: "转写：配置无效，请检查 Base URL、模型和 5–600 秒截止。原配置已保留。"
        case .missingCredentials: "转写：所选服务需要 API 密钥，请补齐钥匙串凭据。音频已保留。"
        case .credentialsUnavailable: "转写：无法访问服务钥匙串，请恢复钥匙串访问。"
        case .authentication: "转写：服务拒绝凭据，请检查密钥后显式重试。"
        case .quota: "转写：服务配额不足，请处理配额后显式重试。"
        case .rateLimited: "转写：服务限流，请稍后显式重试。"
        case .incompatible: "转写：模型或端点未提供有效文件转写接口，请检查该角色能力后重试。"
        case .emptyResult: "转写：未返回可用文本，音频已保留，请显式重试。"
        case .responseTooLarge: "转写：响应超过 1 MiB，已取消请求。音频已保留。"
        case .resultTooLarge: "转写：有效文本超过 256 KiB，未保存或上屏。音频已保留。"
        case .networkUnavailable: "转写：网络或本地服务连接失败，请检查地址、网络和局域网权限后显式重试。"
        case .transportSecurity: "转写：系统传输安全限制了连接，请检查 HTTPS 或本地服务配置。"
        case .serviceUnavailable: "转写：服务请求失败，音频已保留，请显式重试。"
        case .timedOut: "转写：整体请求截止已到，已取消网络任务。音频已保留，请显式重试。"
        case .storageFailure: "转写：结果未能安全保存，不能下载或上屏。音频仍保留；不会自动重发。"
        case .interruptedRequest: "转写：上次请求结果未确认，音频已保留。请显式重试，不会自动重发。"
        }
    }
}

public struct TranscriptionRecord: Codable, Equatable, Sendable {
    public var status: TranscriptionStatus
    public var attemptID: UUID?
    public var serviceID: UUID?
    public var model: String?
    public var failure: TranscriptionFailure?
}

public enum DeliveryStatus: String, Codable, Sendable {
    case waiting, manual, delivered, uncertain, skipped
}

public struct TextDeliveryTarget: Hashable, Sendable {
    public let id: UUID
    public init() { id = UUID() }
}
public enum TextDeliveryResult: Equatable, Sendable { case delivered, manual, uncertain }

@MainActor
public protocol TextDelivering {
    func captureTarget() -> TextDeliveryTarget?
    func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult
    func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult
    func releaseTarget(_ target: TextDeliveryTarget)
    func copy(_ text: String)
}

@MainActor
public protocol RequestTiming {
    var instant: TimeInterval { get }
    func wait(until deadline: TimeInterval) async throws
}

@MainActor
public struct ContinuousRequestTiming: RequestTiming {
    public init() {}
    public var instant: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func wait(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - instant)))
    }
}

@MainActor
public struct TranscriptionDependencies {
    let settings: ServiceSettings
    let credentials: any ServiceCredentialStoring
    let networkConfiguration: URLSessionConfiguration
    let delivery: any TextDelivering
    let timing: any RequestTiming
    public init(settings: ServiceSettings, credentials: any ServiceCredentialStoring,
                networkConfiguration: URLSessionConfiguration = .ephemeral,
                delivery: any TextDelivering, timing: any RequestTiming = ContinuousRequestTiming()) {
        self.settings = settings; self.credentials = credentials; self.networkConfiguration = networkConfiguration
        self.delivery = delivery; self.timing = timing
    }
}

@MainActor
final class TranscriptionAttempt {
    let id: UUID
    let deadline: TimeInterval
    var deadlineTask: Task<Void, Never>?
    private let session: URLSession
    private let task: URLSessionDataTask
    init(id: UUID, deadline: TimeInterval, url: URL, model: String, key: String?, audio: Data,
         configuration: URLSessionConfiguration, completed: @escaping @Sendable (Result<String, TranscriptionFailure>) -> Void) {
        self.id = id; self.deadline = deadline
        let boundary = "QD-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 600
        let delegate = BoundedTranscriptionResponse(completed: completed)
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        task = session.dataTask(with: request)
    }
    func start() { task.resume() }
    func cancel() { deadlineTask?.cancel(); task.cancel(); session.invalidateAndCancel() }
    func finish() { deadlineTask?.cancel(); session.finishTasksAndInvalidate() }
}

private final class BoundedTranscriptionResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var body = Data()
    private var failure: TranscriptionFailure?
    private var status = 0
    private let completed: @Sendable (Result<String, TranscriptionFailure>) -> Void
    private let limit = 1_024 * 1_024
    init(completed: @escaping @Sendable (Result<String, TranscriptionFailure>) -> Void) { self.completed = completed }
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
        // 服务变更必须由用户明确配置，不能把音频或凭据重定向到另一个地址。
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
        if let failure { completed(.failure(failure)); return }
        if let error = error as? URLError {
            completed(.failure(error.code == .appTransportSecurityRequiresSecureConnection ? .transportSecurity : .networkUnavailable)); return
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 401 || status == 403 { completed(.failure(.authentication)); return }
        if status == 429 {
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            completed(.failure(code == "insufficient_quota" ? .quota : .rateLimited)); return
        }
        guard (200...299).contains(status) else {
            completed(.failure([400, 404, 405, 415, 422].contains(status) ? .incompatible : .serviceUnavailable)); return
        }
        guard let text = object?["text"] as? String else { completed(.failure(.incompatible)); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completed(.failure(.emptyResult)); return }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }) else {
            completed(.failure(.emptyResult)); return
        }
        guard text.utf8.count <= 256 * 1_024 else { completed(.failure(.resultTooLarge)); return }
        completed(.success(text))
    }
}
