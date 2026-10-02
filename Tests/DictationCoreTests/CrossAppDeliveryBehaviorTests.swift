import AppKit
import Foundation
import Testing
@testable import DictationCore

@MainActor
@Suite
struct CrossAppDeliveryBehaviorTests {
    @Test
    func recordingTargetReplacesOnlyTheSelectedTextAndPreservesNewClipboardContent() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.document.string = "保留😀旧文字结尾"
        environment.first.document.setSelectedRange(NSRange(location: 4, length: 3))
        let target = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(target) }
        environment.pasteboard.clearContents()
        environment.pasteboard.setString("等待时用户新复制", forType: .string)
        let changeCount = environment.pasteboard.changeCount

        #expect(delivery.deliver("新输入", to: target) == .delivered)
        #expect(environment.first.document.string == "保留😀新输入结尾")
        #expect(environment.first.document.selectedRange() == NSRange(location: 7, length: 0))
        #expect(environment.pasteboard.string(forType: .string) == "等待时用户新复制")
        #expect(environment.pasteboard.changeCount == changeCount)
    }

    @Test
    func userInputDuringTargetCaptureRequiresManualDeliveryEvenIfTheSnapshotLooksUnchanged() {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.document.string = "原文"
        environment.first.duringObservation = { environment.inputHandler?() }

        #expect(delivery.captureTarget() == nil)
        #expect(environment.first.document.string == "原文")
        #expect(environment.inputHandler == nil)
    }

    @Test
    func changingTheModeDoesNotRetargetEarlierSegmentsAndCurrentCursorCanStartWithoutAnInput() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.document.string = "录音起点"
        let recordingTarget = try #require(delivery.captureTarget())
        delivery.updateConfiguration(.init(mode: .currentCursor))
        environment.focused = nil
        let currentCursorTarget = try #require(delivery.captureTarget())
        delivery.updateConfiguration(.init(mode: .recordingTarget))
        environment.focused = environment.second
        environment.second.document.string = "交付时文档："
        environment.second.document.setSelectedRange(NSRange(location: 6, length: 0))
        defer { delivery.releaseTarget(recordingTarget); delivery.releaseTarget(currentCursorTarget) }

        #expect(delivery.deliver("不能改投", to: recordingTarget) == .manual)
        #expect(delivery.deliver("当前结果", to: currentCursorTarget) == .delivered)
        #expect(environment.first.document.string == "录音起点")
        #expect(environment.second.document.string == "交付时文档：当前结果")
        #expect(delivery.deliver("重复", to: currentCursorTarget) == .manual)
        #expect(environment.second.document.string == "交付时文档：当前结果")
    }

    @Test(arguments: DeliveryGuardChange.allCases)
    func recordingTargetProtectsAgainstChangedOrUnverifiableInput(_ change: DeliveryGuardChange) throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.document.string = "原文"
        environment.first.document.setSelectedRange(NSRange(location: 2, length: 0))
        let target = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(target) }
        switch change {
        case .focusChangedThenReturned: environment.first.emit(.focusChanged)
        case .destroyed: environment.first.emit(.destroyed)
        case .typingThenUndo: environment.inputHandler?()
        case .textEditedWithoutNotification: environment.first.document.string = "用户编辑"
        case .cursorMovedWithoutNotification: environment.first.document.setSelectedRange(NSRange(location: 0, length: 0))
        case .readOnly: environment.first.writable = false
        case .unreadable: environment.first.readable = false
        case .permissionRevoked: environment.accessibilityAuthorized = false
        case .secureInput: environment.secureInputActive = true
        case .otherInputWithoutNotification: environment.focused = environment.second
        case .unattributedValueNotification: environment.first.emit(.valueChanged)
        case .unattributedSelectionNotification: environment.first.emit(.selectionChanged)
        }
        let preserved = environment.first.document.string
        #expect(delivery.deliver("不应写入", to: target) == .manual)
        #expect(environment.first.document.string == preserved)
        #expect(environment.second.document.string.isEmpty)
    }

    @Test
    func verifiedSystemWritesAdvanceWaitingSegmentsAndLaterUserTypingStillInvalidatesThem() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        let first = try #require(delivery.captureTarget())
        let second = try #require(delivery.captureTarget())
        let third = try #require(delivery.captureTarget())
        defer { for target in [first, second, third] { delivery.releaseTarget(target) } }
        #expect(delivery.deliver("甲。", to: first) == .delivered)
        #expect(delivery.deliver("乙。", to: second) == .delivered)
        environment.first.document.insertText("用户手打", replacementRange: environment.first.document.selectedRange())
        environment.inputHandler?()
        environment.first.emit(.valueChanged)

        #expect(delivery.deliver("丙。", to: third) == .manual)
        #expect(environment.first.document.string == "甲。乙。用户手打")
    }

    @Test(arguments: [false, true])
    func onlyBoundedNotificationsMatchingVerifiedSystemWritesCanAdvanceWaitingSegments(_ expired: Bool) throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.notifyWrites = false
        let first = try #require(delivery.captureTarget())
        let second = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(first); delivery.releaseTarget(second) }
        #expect(delivery.deliver("甲。", to: first) == .delivered)
        environment.instant = expired ? 10.6 : 10.2
        environment.first.emit(.valueChanged)
        environment.first.emit(.selectionChanged)
        #expect(delivery.deliver("乙。", to: second) == (expired ? .manual : .delivered))
        #expect(environment.first.document.string == (expired ? "甲。" : "甲。乙。"))
    }

    @Test(arguments: DeliveryWriteFault.allCases)
    func anUnverifiedWriteBecomesUncertainAndCannotBeAutomaticallyReplayed(_ fault: DeliveryWriteFault) throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.document.string = "原文"
        environment.first.document.setSelectedRange(NSRange(location: 2, length: 0))
        let first = try #require(delivery.captureTarget())
        let second = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(first); delivery.releaseTarget(second) }
        switch fault {
        case .successWithoutEffect:
            environment.first.performsInsertion = false
            environment.first.notifyWrites = false
        case .errorAfterWriting: environment.first.acceptsInsertion = false
        case .wrongSelection:
            environment.first.afterInsertion = { environment.first.document.setSelectedRange(NSRange(location: 0, length: 0)) }
        case .readbackUnavailable: environment.first.afterInsertion = { environment.first.readable = false }
        case .focusChanged: environment.first.afterInsertion = { environment.focused = environment.second }
        case .permissionRevoked: environment.first.afterInsertion = { environment.accessibilityAuthorized = false }
        case .secureInput: environment.first.afterInsertion = { environment.secureInputActive = true }
        case .userInput: environment.first.afterInsertion = { environment.inputHandler?() }
        }

        #expect(delivery.deliver("甲", to: first) == .uncertain)
        #expect(environment.first.document.string == (fault == .successWithoutEffect ? "原文" : "原文甲"))
        environment.first.performsInsertion = true
        environment.first.acceptsInsertion = true
        environment.first.afterInsertion = nil
        environment.first.readable = true
        environment.accessibilityAuthorized = true
        environment.secureInputActive = false
        environment.focused = environment.first
        let preserved = environment.first.document.string
        #expect(delivery.deliver("甲", to: first) == .manual)
        #expect(delivery.deliver("乙", to: second) == .manual)
        #expect(environment.first.document.string == preserved)
        #expect(environment.second.document.string.isEmpty)
    }

    @Test
    func manualInsertionUsesCurrentInputAndDeliberateCopyChangesOnlyTheClipboard() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.document.string = "旧目标"
        let target = try #require(delivery.captureTarget())
        environment.focused = environment.second
        defer { delivery.releaseTarget(target) }
        #expect(delivery.deliver("结果", to: target) == .manual)
        #expect(delivery.insertAtCurrentCursor("手动结果") == .delivered)
        delivery.copy("复制结果")
        #expect(environment.first.document.string == "旧目标")
        #expect(environment.second.document.string == "手动结果")
        #expect(environment.pasteboard.string(forType: .string) == "复制结果")
    }

    @Test(arguments: [false, true])
    func unreliableMonitoringCannotCreateAnAutomaticTarget(_ observerUnavailable: Bool) {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        if observerUnavailable { environment.first.canObserve = false }
        else { environment.canMonitorInput = false }
        #expect(delivery.captureTarget() == nil)
        #expect(environment.first.document.string.isEmpty)
        #expect(environment.inputHandler == nil)
    }

    @Test
    func duplicateUnattributedNotificationsStillRequireManualDeliveryAfterAVerifiedWrite() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        environment.first.notifyWrites = false
        let first = try #require(delivery.captureTarget())
        let second = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(first); delivery.releaseTarget(second) }
        #expect(delivery.deliver("甲", to: first) == .delivered)
        environment.first.emit(.valueChanged)
        environment.first.emit(.selectionChanged)
        environment.first.emit(.valueChanged)
        #expect(delivery.deliver("乙", to: second) == .manual)
        #expect(environment.first.document.string == "甲")
    }

    @Test
    func savedDeliveryModeSurvivesReloadAndAnUnknownModePreservesItsOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-settings-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("delivery.json")
        let settings = DeliverySettings(file: file)
        #expect(try settings.load().mode == .recordingTarget)
        try settings.save(.init(mode: .currentCursor))
        #expect(try DeliverySettings(file: file).load().mode == .currentCursor)
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        #expect(stored == ["mode": "currentCursor"])
        let unknown = Data("{\"mode\":\"future-mode\"}".utf8)
        try unknown.write(to: file, options: .atomic)
        #expect(throws: DeliverySettingsError.unreadableConfiguration) { try settings.load() }
        #expect(try Data(contentsOf: file) == unknown)
        try settings.save(.init(mode: .recordingTarget))
        #expect(try settings.load().mode == .recordingTarget)
    }

    @Test
    func savingIntoAnUnwritableDirectoryPreservesThePreviousModeOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-settings-\(UUID())", isDirectory: true)
        let file = root.appendingPathComponent("delivery.json")
        let settings = DeliverySettings(file: file)
        try settings.save(.init(mode: .recordingTarget))
        let previous = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(throws: DeliverySettingsError.cannotSave) { try settings.save(.init(mode: .currentCursor)) }
        #expect(try Data(contentsOf: file) == previous)
        #expect(try DeliverySettings(file: file).load().mode == .recordingTarget)
    }

    @Test
    func anEditAfterTheInitialWriteSnapshotIsPreservedBeforeAnyWriteAttempt() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        let target = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(target) }
        environment.first.afterSnapshot = {
            environment.first.document.string = "用户编辑"
            environment.first.document.setSelectedRange(NSRange(location: 4, length: 0))
        }
        #expect(delivery.deliver("口述", to: target) == .manual)
        #expect(environment.first.document.string == "用户编辑")
    }

    @Test
    func observingRevokedAccessibilityKeepsOldTargetsManualAfterAuthorizationReturns() throws {
        let environment = DeliveryTestEnvironment()
        let delivery = CrossAppTextDelivery(environment: environment)
        let oldTarget = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(oldTarget) }
        environment.accessibilityAuthorized = false
        #expect(!delivery.accessibilityAuthorized)
        environment.accessibilityAuthorized = true
        #expect(delivery.deliver("旧结果", to: oldTarget) == .manual)
        #expect(environment.first.document.string.isEmpty)
        let newTarget = try #require(delivery.captureTarget())
        defer { delivery.releaseTarget(newTarget) }
        #expect(delivery.deliver("新结果", to: newTarget) == .delivered)
        #expect(environment.first.document.string == "新结果")
    }

    @Test
    func inputWindowGeometryUsesTheMenuBarScreenOriginAndRejectsUnknownMappings() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let right = CGRect(x: 1_440, y: -300, width: 1_920, height: 1_080)
        let above = CGRect(x: 0, y: 900, width: 1_440, height: 900)
        #expect(crossAppScreenIndex(position: CGPoint(x: 100, y: 50), size: CGSize(width: 100, height: 100),
            screenFrames: [primary, right]) == 0)
        #expect(crossAppScreenIndex(position: CGPoint(x: 1_500, y: 50), size: CGSize(width: 100, height: 100),
            screenFrames: [primary, right]) == 1)
        #expect(crossAppScreenIndex(position: CGPoint(x: 100, y: -750), size: CGSize(width: 400, height: 200),
            screenFrames: [primary, above]) == 1)
        #expect(crossAppScreenIndex(position: CGPoint(x: 1_340, y: 200), size: CGSize(width: 200, height: 200),
            screenFrames: [primary, right]) == nil)
        #expect(crossAppScreenIndex(position: CGPoint(x: 6_000, y: 200), size: CGSize(width: 100, height: 100),
            screenFrames: [primary, right]) == nil)
        #expect(crossAppScreenIndex(position: CGPoint(x: CGFloat.nan, y: 0), size: CGSize(width: 100, height: 100),
            screenFrames: [primary]) == nil)
        #expect(crossAppScreenIndex(position: .zero, size: .zero, screenFrames: [primary]) == nil)
    }
}

enum DeliveryGuardChange: CaseIterable, Sendable {
    case focusChangedThenReturned, destroyed, typingThenUndo, textEditedWithoutNotification, cursorMovedWithoutNotification
    case readOnly, unreadable, permissionRevoked, secureInput, otherInputWithoutNotification
    case unattributedValueNotification, unattributedSelectionNotification
}

enum DeliveryWriteFault: CaseIterable, Sendable {
    case successWithoutEffect, errorAfterWriting, wrongSelection, readbackUnavailable, focusChanged, permissionRevoked, secureInput, userInput
}

@MainActor
private final class DeliveryTestEnvironment: CrossAppTextEnvironment {
    var accessibilityAuthorized = true
    var secureInputActive = false
    var instant: TimeInterval = 10
    let first = DeliveryTestInput()
    let second = DeliveryTestInput()
    var focused: DeliveryTestInput?
    var canMonitorInput = true
    var inputHandler: (() -> Void)?
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("queued-dictation-test-\(UUID())"))

    init() { focused = first }
    func focusedInput() -> (any CrossAppTextInput)? { focused }
    func monitorUserInput(_ handler: @escaping @MainActor () -> Void) -> Bool {
        guard canMonitorInput else { return false }
        inputHandler = handler
        return true
    }
    func stopMonitoringUserInput() { inputHandler = nil }
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

@MainActor
private final class DeliveryTestInput: CrossAppTextInput {
    let document = NSTextView()
    var writable = true
    var readable = true
    var canObserve = true
    var duringObservation: (() -> Void)?
    var performsInsertion = true
    var acceptsInsertion = true
    var notifyWrites = true
    var afterInsertion: (() -> Void)?
    var afterSnapshot: (() -> Void)?
    private var handlers: [UUID: (CrossAppInputEvent) -> Void] = [:]

    func isSameInput(as other: any CrossAppTextInput) -> Bool { (other as? DeliveryTestInput) === self }
    func readSnapshot() -> CrossAppInputSnapshot? {
        guard writable, readable else { return nil }
        let snapshot = CrossAppInputSnapshot(text: document.string, selection: document.selectedRange())
        let action = afterSnapshot
        afterSnapshot = nil
        action?()
        return snapshot
    }
    func observe(_ handler: @escaping @MainActor (CrossAppInputEvent) -> Void) -> (any CrossAppInputObservation)? {
        guard canObserve else { return nil }
        let id = UUID()
        handlers[id] = handler
        duringObservation?()
        return DeliveryTestObservation { [weak self] in self?.handlers[id] = nil }
    }
    func insertSelectedText(_ text: String) -> Bool {
        if performsInsertion { document.insertText(text, replacementRange: document.selectedRange()) }
        afterInsertion?()
        if notifyWrites { emit(.valueChanged); emit(.selectionChanged) }
        return acceptsInsertion
    }
    func emit(_ event: CrossAppInputEvent) { for handler in Array(handlers.values) { handler(event) } }
}

@MainActor
private final class DeliveryTestObservation: CrossAppInputObservation {
    private var stopAction: (() -> Void)?
    init(_ stop: @escaping () -> Void) { stopAction = stop }
    func stop() { stopAction?(); stopAction = nil }
}
