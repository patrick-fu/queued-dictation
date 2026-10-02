import Foundation

public struct QueueLimits: Sendable {
    public let maximumPendingSegments: Int
    public let maximumPendingDuration: TimeInterval
    public let maximumPendingAudioBytes: UInt64
    public init(maximumPendingSegments: Int = 20, maximumPendingDuration: TimeInterval = 30 * 60,
                maximumPendingAudioBytes: UInt64 = 256 * 1_024 * 1_024) {
        self.maximumPendingSegments = maximumPendingSegments
        self.maximumPendingDuration = maximumPendingDuration
        self.maximumPendingAudioBytes = maximumPendingAudioBytes
    }
}

public enum QueueStage: String, Codable, Sendable {
    case recording, waitingForSlot, waitingForConfiguration, waitingForNetwork, waitingForBackoff, transcribing
    case waitingForPolishSlot, waitingForPolishConfiguration, polishing, waitingForResume
    case readyForDelivery, waitingForPredecessor, awaitingManualDelivery, deliveryUncertain
    case failed, timedOut, interrupted, completed, skipped, cancelled
    public var title: String {
        switch self {
        case .recording: "正在录音"
        case .waitingForSlot: "等待主流程请求槽位"
        case .waitingForConfiguration: "等待转写配置"
        case .waitingForNetwork: "等待网络路由；请求尚未发送"
        case .waitingForBackoff: "等待所选服务 Retry-After；请求尚未发送"
        case .transcribing: "正在转写"
        case .waitingForPolishSlot: "润色等待主流程请求槽位"
        case .waitingForPolishConfiguration: "等待润色配置"
        case .polishing: "正在润色"
        case .waitingForResume: "超出自动发送时间窗，等待主动恢复"
        case .readyForDelivery: "准备上屏"
        case .waitingForPredecessor: "等待前段放行"
        case .awaitingManualDelivery: "等待手动上屏"
        case .deliveryUncertain: "写回结果不确定"
        case .failed: "转写失败"
        case .timedOut: "转写超时"
        case .interrupted: "等待显式恢复"
        case .completed: "已上屏"
        case .skipped: "已跳过主交付"
        case .cancelled: "已取消"
        }
    }
}

public struct QueueSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let recordingOrder: UInt64?
    public let recordedAt: Date
    public let duration: TimeInterval
    public let stage: QueueStage
    public let reason: String?
    public let hasText: Bool
    public let isHead: Bool
}

public struct QueueUsage: Equatable, Sendable {
    public let segments: Int
    public let duration: TimeInterval
    public let audioBytes: UInt64
}

public enum MainRequestRole: Sendable { case transcription, polish }

@MainActor
public final class MainRequestBudget {
    public private(set) var limit: Int
    public var activeCount: Int { slots.count }
    var onSlotAvailable: (() -> Void)?
    private var slots: [UUID: MainRequestRole] = [:]
    init(limit: Int = 3) { self.limit = limit }
    public func acquire(for role: MainRequestRole) -> UUID? {
        guard activeCount < limit else { return nil }
        let token = UUID()
        slots[token] = role
        return token
    }
    public func release(_ token: UUID) {
        guard slots.removeValue(forKey: token) != nil else { return }
        onSlotAvailable?()
    }
    func updateLimit(_ limit: Int) { self.limit = limit; onSlotAvailable?() }
}
