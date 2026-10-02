import Foundation

public struct CoachCard: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { identity.segmentID }
    public let identity: CoachWorkIdentity
    public let rawText: String
    public let feedback: CoachFeedback
    public let inputMode: CoachInputMode
    public init(identity: CoachWorkIdentity, rawText: String, feedback: CoachFeedback, inputMode: CoachInputMode = .text) {
        self.identity = identity; self.rawText = rawText; self.feedback = feedback; self.inputMode = inputMode
    }

    private enum CodingKeys: String, CodingKey { case identity, rawText, feedback, inputMode }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(CoachWorkIdentity.self, forKey: .identity)
        rawText = try values.decode(String.self, forKey: .rawText)
        feedback = try values.decode(CoachFeedback.self, forKey: .feedback)
        inputMode = try values.decodeIfPresent(CoachInputMode.self, forKey: .inputMode) ?? .text
    }
}

public enum CoachPresentation: Equatable, Sendable { case ignored, historyOnly, presented }

public struct CoachPanelState: Equatable, Sendable {
    public private(set) var enabled: Bool
    public private(set) var cards: [CoachCard] = []
    private struct Registration: Equatable, Sendable {
        let identity: CoachWorkIdentity
        let rawText: String
        let inputMode: CoachInputMode
        var mayPresent: Bool
    }
    private var registrations: [UUID: Registration] = [:]
    public init(enabled: Bool = false) { self.enabled = enabled }

    @discardableResult
    public mutating func begin(_ identity: CoachWorkIdentity, rawText: String, inputMode: CoachInputMode = .text) -> Bool {
        guard enabled else { return false }
        registrations[identity.segmentID] = Registration(identity: identity, rawText: rawText, inputMode: inputMode, mayPresent: true)
        return true
    }

    public mutating func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            cards.removeAll()
            for id in registrations.keys { registrations[id]?.mayPresent = false }
        }
    }

    @discardableResult
    public mutating func complete(_ identity: CoachWorkIdentity, result: CoachResult) -> CoachPresentation {
        guard let registration = registrations[identity.segmentID], registration.identity == identity else { return .ignored }
        registrations[identity.segmentID] = nil
        guard enabled, registration.mayPresent, case .card(let feedback) = result else { return .historyOnly }
        cards.removeAll { $0.identity.segmentID == identity.segmentID }
        cards.append(CoachCard(identity: identity, rawText: registration.rawText, feedback: feedback, inputMode: registration.inputMode))
        return .presented
    }

    public mutating func invalidate(_ identity: CoachWorkIdentity) {
        guard registrations[identity.segmentID]?.identity == identity else { return }
        registrations[identity.segmentID] = nil
    }

    public mutating func removeCard(_ segmentID: UUID) { cards.removeAll { $0.identity.segmentID == segmentID } }

    public mutating func removeSegment(_ segmentID: UUID) {
        registrations[segmentID] = nil
        removeCard(segmentID)
    }
}
