import Foundation
import CoreFoundation

public enum CoachFailure: String, Error, Codable, LocalizedError, Sendable {
    case disabled, missingConfiguration, invalidConfiguration, missingCredentials, credentialsUnavailable
    case authentication, quota, rateLimited, incompatible, invalidResult, responseTooLarge, inputTooLarge
    case networkUnavailable, transportSecurity, serviceUnavailable, timedOut, cancelled, storageFailure
    case missingAudio, audioUnavailable, invalidAudio, audioTooLarge, audioIncompatible
    case interruptedRequest
    public var errorDescription: String? {
        switch self {
        case .disabled: "英语带教已关闭。"
        case .missingConfiguration: "英语带教：尚未选择共享服务和带教模型，主输入继续。"
        case .invalidConfiguration: "英语带教：配置无效，请检查服务、模型、1–10 并发、5–600 秒截止和完整提示词。"
        case .missingCredentials: "英语带教：所选服务需要 API 密钥，请补齐共享服务的钥匙串凭据。"
        case .credentialsUnavailable: "英语带教：无法访问服务钥匙串，请恢复钥匙串访问。"
        case .authentication: "英语带教：服务拒绝凭据，请检查共享服务密钥后显式重试。"
        case .quota: "英语带教：服务配额不足，请处理配额后显式重试。"
        case .rateLimited: "英语带教：服务限流，请稍后显式重试。"
        case .incompatible: "英语带教：服务或模型未提供兼容的 Chat 响应，请核验所选带教方式的能力。"
        case .invalidResult: "英语带教：结果不符合卡片契约，没有展示卡片；不会发送额外修复请求。"
        case .responseTooLarge: "英语带教：响应超过 1 MiB，已取消请求，没有展示卡片。"
        case .inputTooLarge: "英语带教：原始转写超过 256 KiB 或内容无效，没有发送请求。"
        case .networkUnavailable: "英语带教：网络或本地服务连接失败，请检查地址、网络与局域网权限。"
        case .transportSecurity: "英语带教：系统传输安全限制了连接，请检查 HTTPS 或本地服务配置。"
        case .serviceUnavailable: "英语带教：服务请求失败，请显式重试。"
        case .timedOut: "英语带教：完整请求截止已到，已取消请求并忽略迟到结果。"
        case .cancelled: "英语带教：本次请求已取消。"
        case .storageFailure: "英语带教：结果或尝试状态未能安全保存，没有展示卡片；不会自动重发。"
        case .missingAudio: "英语带教：本段没有可用的原始音频，未发送请求。可在带教设置切换为文本方式后显式重试；文本方式不能评流利度。"
        case .audioUnavailable: "英语带教：无法从加密历史读取本段原音频，未发送请求。可修复历史访问，或切换为文本方式后显式重试。"
        case .invalidAudio: "英语带教：本段原音频不是有效的单声道 16 位 PCM WAV，未发送请求。可切换为文本方式后显式重试。"
        case .audioTooLarge: "英语带教：原音频超过 60 分钟或有界请求大小，未发送请求。可切换为文本方式后显式重试。"
        case .audioIncompatible: "英语带教：服务或模型未提供兼容的 WAV 音频 Chat 响应。请核验音频能力，或切换为文本方式后显式重试；不会自动再发文本请求。"
        case .interruptedRequest: "英语带教：上次请求结果未确认，请显式重试；不会自动重发或重放旧卡。"
        }
    }
}

public enum CoachSuggestionCategory: String, Codable, Sendable { case grammar, expression, fluency }

public struct CoachAudioEvidence: Codable, Equatable, Sendable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let observation: String
    public init(startSeconds: TimeInterval, endSeconds: TimeInterval, observation: String) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.observation = observation
    }
}

public struct CoachSuggestion: Codable, Equatable, Sendable {
    public let category: CoachSuggestionCategory
    public let original: String
    public let improved: String
    public let reason: String
    public let audioEvidence: CoachAudioEvidence?
    public init(category: CoachSuggestionCategory, original: String, improved: String, reason: String,
                audioEvidence: CoachAudioEvidence? = nil) {
        self.category = category; self.original = original; self.improved = improved; self.reason = reason
        self.audioEvidence = audioEvidence
    }
}

public struct CoachFeedback: Codable, Equatable, Sendable {
    public let suggestions: [CoachSuggestion]
    public init(suggestions: [CoachSuggestion]) { self.suggestions = suggestions }
}

public enum CoachResult: Codable, Equatable, Sendable {
    case noCard
    case card(CoachFeedback)

    public static func validate(content: String, rawText: String, audioDuration: TimeInterval? = nil) throws -> CoachResult {
        guard let data = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = object["kind"] as? String else { throw CoachFailure.invalidResult }
        if kind == "no_card", Set(object.keys) == ["kind"] { return .noCard }
        guard kind == "card", Set(object.keys) == ["kind", "suggestions"],
              let entries = object["suggestions"] as? [[String: Any]], (1...2).contains(entries.count) else {
            throw CoachFailure.invalidResult
        }
        var suggestions: [CoachSuggestion] = []
        for entry in entries {
            guard let categoryName = entry["category"] as? String,
                  let category = CoachSuggestionCategory(rawValue: categoryName),
                  let improved = entry["improved"] as? String,
                  let reason = entry["reason"] as? String,
                  [improved, reason].allSatisfy({ CoachSettings.validText($0, maximumBytes: 8_192) }) else {
                throw CoachFailure.invalidResult
            }
            if category == .fluency {
                guard Set(entry.keys) == ["category", "improved", "reason", "audioEvidence"],
                      let duration = audioDuration, duration.isFinite, duration > 0,
                      let evidence = entry["audioEvidence"] as? [String: Any],
                      Set(evidence.keys) == ["startSeconds", "endSeconds", "observation"],
                      let start = seconds(evidence["startSeconds"]), let end = seconds(evidence["endSeconds"]),
                      start >= 0, start < end, end <= duration,
                      let observation = evidence["observation"] as? String,
                      CoachSettings.validText(observation, maximumBytes: 8_192) else { throw CoachFailure.invalidResult }
                suggestions.append(CoachSuggestion(category: category, original: "", improved: improved, reason: reason,
                    audioEvidence: CoachAudioEvidence(startSeconds: start, endSeconds: end, observation: observation)))
            } else {
                guard Set(entry.keys) == ["category", "original", "improved", "reason"],
                      let original = entry["original"] as? String, CoachSettings.validText(original, maximumBytes: 8_192),
                      rawText.contains(original), original.trimmingCharacters(in: .whitespacesAndNewlines) != improved.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw CoachFailure.invalidResult
                }
                suggestions.append(CoachSuggestion(category: category, original: original, improved: improved, reason: reason))
            }
        }
        return .card(CoachFeedback(suggestions: suggestions))
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

public struct CoachWorkIdentity: Codable, Equatable, Hashable, Sendable {
    public let segmentID: UUID
    public let attemptID: UUID
    public init(segmentID: UUID, attemptID: UUID = UUID()) { self.segmentID = segmentID; self.attemptID = attemptID }
}

public struct CoachDispatch: Codable, Equatable, Sendable {
    public let identity: CoachWorkIdentity
    public let serviceID: UUID
    public let model: String
    public let prompt: String
    public let timeout: TimeInterval
    public let audioUsed: Bool
    public let audioFormat: String?
    public let audioDuration: TimeInterval?
    public var inputMode: CoachInputMode { audioUsed ? .originalAudio : .text }

    public init(identity: CoachWorkIdentity, serviceID: UUID, model: String, prompt: String, timeout: TimeInterval,
                audioUsed: Bool = false, audioFormat: String? = nil, audioDuration: TimeInterval? = nil) {
        self.identity = identity; self.serviceID = serviceID; self.model = model; self.prompt = prompt; self.timeout = timeout
        self.audioUsed = audioUsed; self.audioFormat = audioFormat; self.audioDuration = audioDuration
    }

    private enum CodingKeys: String, CodingKey { case identity, serviceID, model, prompt, timeout, audioUsed, audioFormat, audioDuration }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(CoachWorkIdentity.self, forKey: .identity)
        serviceID = try values.decode(UUID.self, forKey: .serviceID)
        model = try values.decode(String.self, forKey: .model)
        prompt = try values.decode(String.self, forKey: .prompt)
        timeout = try values.decode(TimeInterval.self, forKey: .timeout)
        audioUsed = try values.decodeIfPresent(Bool.self, forKey: .audioUsed) ?? false
        audioFormat = try values.decodeIfPresent(String.self, forKey: .audioFormat)
        audioDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
    }
}
