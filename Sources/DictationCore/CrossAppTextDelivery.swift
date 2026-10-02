import AppKit
import CryptoKit

@MainActor
public final class CrossAppTextDelivery: TextDelivering {
    public private(set) var configuration: DeliveryConfiguration
    public var automaticDeliveryEnabled = true
    public var accessibilityAuthorized: Bool {
        let authorized = environment.accessibilityAuthorized
        if !authorized { invalidateCapturedInputs() }
        return authorized
    }
    public var currentInputScreen: NSScreen? {
        guard inputAccessible else { return nil }
        return environment.currentInputScreen
    }
    private let environment: any CrossAppTextEnvironment
    private var targets: [UUID: FrozenDeliveryTarget] = [:]
    private var monitoringInput = false
    private var activeInput: CapturedCrossAppInput?
    private var writing = false
    private var inputRevision: UInt64 = 0

    init(environment: any CrossAppTextEnvironment, configuration: DeliveryConfiguration = .init()) {
        self.environment = environment
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: DeliveryConfiguration) { self.configuration = configuration }

    public func captureTarget() -> TextDeliveryTarget? {
        guard automaticDeliveryEnabled else { return nil }
        let token = TextDeliveryTarget()
        switch configuration.mode {
        case .recordingTarget:
            guard let captured = captureCurrentInput() else { stopMonitoringIfUnused(); return nil }
            targets[token.id] = .recording(captured)
        case .currentCursor:
            // 此模式在真正交付时取焦点；录音起点没有输入框仍可排队。
            targets[token.id] = .currentCursor
        }
        return token
    }

    public func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard !writing, let frozen = targets[target.id] else { return .manual }
        if case .spent = frozen { return .manual }
        writing = true
        defer {
            writing = false
            if case .recording(let captured) = frozen { captured.stop() }
            targets[target.id] = .spent
            activeInput?.stop()
            activeInput = nil
            stopMonitoringIfUnused()
        }
        guard automaticDeliveryEnabled else { return .manual }
        let captured: CapturedCrossAppInput
        switch frozen {
        case .recording(let original): captured = original
        case .currentCursor:
            guard let current = captureCurrentInput() else { return .manual }
            activeInput = current
            captured = current
        case .spent: return .manual
        }
        return write(text, to: captured)
    }

    public func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult {
        guard !writing else { return .manual }
        writing = true
        defer {
            writing = false
            activeInput?.stop()
            activeInput = nil
            stopMonitoringIfUnused()
        }
        guard let current = captureCurrentInput() else { return .manual }
        activeInput = current
        return write(text, to: current)
    }

    public func releaseTarget(_ target: TextDeliveryTarget) {
        if case .recording(let captured) = targets.removeValue(forKey: target.id) { captured.stop() }
        stopMonitoringIfUnused()
    }

    public func copy(_ text: String) { environment.copy(text) }

    private var inputAccessible: Bool {
        guard accessibilityAuthorized else { return false }
        guard !environment.secureInputActive else { invalidateCapturedInputs(); return false }
        return true
    }

    private func invalidateCapturedInputs() {
        for frozen in targets.values {
            if case .recording(let captured) = frozen { captured.invalidated = true; captured.stop() }
        }
        activeInput?.invalidated = true
        activeInput?.stop()
        if monitoringInput { environment.stopMonitoringUserInput(); monitoringInput = false }
    }

    private func captureCurrentInput() -> CapturedCrossAppInput? {
        let revision = inputRevision
        guard inputAccessible else { return nil }
        if !monitoringInput {
            monitoringInput = environment.monitorUserInput { [weak self] in
                guard let self else { return }
                self.inputRevision &+= 1
                for frozen in self.targets.values {
                    if case .recording(let captured) = frozen { captured.invalidated = true }
                }
                self.activeInput?.invalidated = true
            }
            guard monitoringInput else { return nil }
        }
        guard let input = environment.focusedInput(),
              let snapshot = input.readSnapshot(), snapshot.valid else { return nil }
        let captured = CapturedCrossAppInput(input: input, state: snapshot.state)
        guard let observation = input.observe({ [weak self, weak captured] event in
            guard let self, let captured else { return }
            self.changed(captured, event: event)
        }) else { return nil }
        captured.observation = observation
        guard inputRevision == revision, !captured.invalidated, inputAccessible,
              let focus = environment.focusedInput(), focus.isSameInput(as: input),
              let after = input.readSnapshot(), after.valid, after.state == snapshot.state,
              inputRevision == revision, !captured.invalidated else {
            captured.stop()
            return nil
        }
        return captured
    }

    private func write(_ text: String, to captured: CapturedCrossAppInput) -> TextDeliveryResult {
        guard !captured.invalidated, inputAccessible,
              let focus = environment.focusedInput(), focus.isSameInput(as: captured.input),
              let before = captured.input.readSnapshot(), before.valid, before.state == captured.state,
              !captured.invalidated else { return .manual }
        let expectedText = (before.text as NSString).replacingCharacters(in: before.selection, with: text)
        let expected = CrossAppInputSnapshot(text: expectedText,
            selection: NSRange(location: before.selection.location + (text as NSString).length, length: 0))
        guard expected.valid else { return .manual }
        var cohort = targets.values.compactMap { frozen -> CapturedCrossAppInput? in
            guard case .recording(let other) = frozen, !other.invalidated,
                  other.input.isSameInput(as: captured.input), other.state == before.state else { return nil }
            return other
        }
        if !cohort.contains(where: { $0 === captured }) { cohort.append(captured) }
        for other in cohort { other.prepareWrite(expected.state, at: environment.instant) }
        // 目标 App 可在 AX 查询返回后继续编辑；实际写入前再次核验。
        guard !captured.invalidated, inputAccessible,
              let readyFocus = environment.focusedInput(), readyFocus.isSameInput(as: captured.input),
              let readySnapshot = captured.input.readSnapshot(), readySnapshot.valid,
              readySnapshot.state == before.state, !captured.invalidated else {
            for other in cohort { other.invalidated = true }
            return .manual
        }
        guard captured.input.insertSelectedText(text),
              !captured.invalidated, inputAccessible,
              let afterFocus = environment.focusedInput(), afterFocus.isSameInput(as: captured.input),
              let after = captured.input.readSnapshot(), after.valid,
              after.text == expected.text, after.selection == expected.selection,
              !captured.invalidated else {
            for other in cohort { other.invalidated = true }
            return .uncertain
        }
        // 只推进同控件、同旧快照且仍有效的等待片段；用户编辑不会被恢复为有效。
        for other in cohort where !other.invalidated { other.state = expected.state }
        return .delivered
    }

    private func changed(_ captured: CapturedCrossAppInput, event: CrossAppInputEvent) {
        guard !captured.invalidated,
              event == .valueChanged || event == .selectionChanged,
              inputAccessible,
              let focus = environment.focusedInput(), focus.isSameInput(as: captured.input),
              let snapshot = captured.input.readSnapshot(), snapshot.valid,
              captured.acceptSystemEvent(event, state: snapshot.state, at: environment.instant) else {
            captured.invalidated = true
            return
        }
    }

    private func stopMonitoringIfUnused() {
        guard activeInput == nil, !targets.values.contains(where: {
            if case .recording = $0 { return true }
            return false
        }) else { return }
        if monitoringInput { environment.stopMonitoringUserInput(); monitoringInput = false }
    }
}

private enum FrozenDeliveryTarget {
    case recording(CapturedCrossAppInput), currentCursor, spent
}

@MainActor
private final class CapturedCrossAppInput {
    let input: any CrossAppTextInput
    var state: CrossAppInputState
    var invalidated = false
    var observation: (any CrossAppInputObservation)?
    private var expected: CrossAppInputState?
    private var notifications: [CrossAppInputEvent: Int] = [:]
    private var deadline: TimeInterval = 0
    init(input: any CrossAppTextInput, state: CrossAppInputState) { self.input = input; self.state = state }

    func prepareWrite(_ state: CrossAppInputState, at instant: TimeInterval) {
        if instant > deadline { notifications = [:] }
        expected = state
        notifications[.valueChanged, default: 0] += 1
        notifications[.selectionChanged, default: 0] += 1
        deadline = instant + 0.5
    }
    func acceptSystemEvent(_ event: CrossAppInputEvent, state: CrossAppInputState, at instant: TimeInterval) -> Bool {
        guard instant <= deadline, notifications[event, default: 0] > 0, expected == state else { return false }
        notifications[event, default: 0] -= 1
        return true
    }
    func stop() { observation?.stop(); observation = nil }
}

struct CrossAppInputSnapshot {
    let text: String
    let selection: NSRange
    var valid: Bool {
        let length = (text as NSString).length
        return text.utf8.count <= 1_024 * 1_024 && selection.location >= 0 && selection.length >= 0
            && selection.location <= length && selection.length <= length - selection.location
    }
    var state: CrossAppInputState { CrossAppInputState(fingerprint: Data(SHA256.hash(data: Data(text.utf8))), selection: selection) }
}

struct CrossAppInputState: Equatable {
    let fingerprint: Data
    let selection: NSRange
}

enum CrossAppInputEvent: Hashable { case valueChanged, selectionChanged, focusChanged, destroyed }

@MainActor
protocol CrossAppTextEnvironment {
    var accessibilityAuthorized: Bool { get }
    var secureInputActive: Bool { get }
    var instant: TimeInterval { get }
    var currentInputScreen: NSScreen? { get }
    func focusedInput() -> (any CrossAppTextInput)?
    func monitorUserInput(_ handler: @escaping @MainActor () -> Void) -> Bool
    func stopMonitoringUserInput()
    func copy(_ text: String)
}

extension CrossAppTextEnvironment {
    var currentInputScreen: NSScreen? { nil }
}

@MainActor
protocol CrossAppTextInput: AnyObject {
    func isSameInput(as other: any CrossAppTextInput) -> Bool
    func readSnapshot() -> CrossAppInputSnapshot?
    func observe(_ handler: @escaping @MainActor (CrossAppInputEvent) -> Void) -> (any CrossAppInputObservation)?
    func insertSelectedText(_ text: String) -> Bool
}

protocol CrossAppInputObservation { @MainActor func stop() }
