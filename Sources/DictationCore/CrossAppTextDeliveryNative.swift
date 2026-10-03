import AppKit
import ApplicationServices
import Carbon

public extension CrossAppTextDelivery {
    convenience init(configuration: DeliveryConfiguration = .init()) {
        self.init(environment: NativeCrossAppTextEnvironment(), configuration: configuration)
    }
}

@MainActor
private final class NativeCrossAppTextEnvironment: CrossAppTextEnvironment {
    var accessibilityAuthorized: Bool { AXIsProcessTrusted() }
    var secureInputActive: Bool { IsSecureEventInputEnabled() }
    var instant: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var monitor: NativeCrossAppUserInputMonitor?

    var currentInputScreen: NSScreen? {
        guard let input = focusedInput() as? NativeCrossAppTextInput,
              let rawPosition = crossAppAttribute(input.window, kAXPositionAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = crossAppAttribute(input.window, kAXSizeAttribute),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetType(sizeValue) == .cgSize, AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let screens = NSScreen.screens
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == input.pid,
              let focus = crossAppElementAttribute(input.application, kAXFocusedUIElementAttribute),
              CFEqual(focus, input.element),
              let window = crossAppElementAttribute(focus, kAXWindowAttribute), CFEqual(window, input.window),
              let index = crossAppScreenIndex(position: position, size: size, screenFrames: screens.map(\.frame)) else { return nil }
        return screens[index]
    }

    func focusedInput() -> (any CrossAppTextInput)? {
        guard accessibilityAuthorized, !secureInputActive,
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = crossAppElementAttribute(application, kAXFocusedUIElementAttribute),
              let window = crossAppElementAttribute(element, kAXWindowAttribute),
              crossAppOrdinaryWritable(element) else { return nil }
        return NativeCrossAppTextInput(application: application, element: element, window: window, pid: app.processIdentifier)
    }

    func monitorUserInput(_ handler: @escaping @MainActor () -> Void) -> Bool {
        if monitor != nil { return true }
        monitor = NativeCrossAppUserInputMonitor(handler: handler)
        return monitor != nil
    }

    func stopMonitoringUserInput() {
        monitor?.stop()
        monitor = nil
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

func crossAppScreenIndex(position: CGPoint, size: CGSize, screenFrames: [CGRect]) -> Int? {
    guard let primary = screenFrames.first,
          position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0,
          screenFrames.allSatisfy({ $0.minX.isFinite && $0.maxX.isFinite && $0.minY.isFinite && $0.maxY.isFinite
              && $0.width > 0 && $0.height > 0 }) else { return nil }
    // AX 原点在菜单栏屏幕左上，AppKit 在该屏幕左下；两者均使用点。
    let frame = CGRect(x: position.x, y: primary.maxY - position.y - size.height, width: size.width, height: size.height)
    guard frame.minX.isFinite, frame.maxX.isFinite, frame.minY.isFinite, frame.maxY.isFinite else { return nil }
    var selected: Int?
    var maximumArea: CGFloat = 0
    for (index, screen) in screenFrames.enumerated() {
        let overlap = screen.intersection(frame)
        let area = overlap.isNull ? 0 : overlap.width * overlap.height
        guard area.isFinite else { return nil }
        if area > maximumArea { selected = index; maximumArea = area }
        else if area > 0, area == maximumArea { selected = nil }
    }
    return selected
}

@MainActor
func crossAppLocalInputRequiresInvalidation(_ event: NSEvent) -> Bool {
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        guard let panel = event.window as? NSPanel, panel.styleMask.contains(.nonactivatingPanel),
              !panel.canBecomeKey, !panel.canBecomeMain else { return true }
        return false
    default: return true
    }
}

func crossAppCharacterCountMatches(_ value: CFTypeRef, utf16Length: Int) -> Bool {
    guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else { return false }
    let count = number.doubleValue
    return count.isFinite && count == Double(utf16Length)
}

private final class NativeCrossAppUserInputMonitor {
    private let notificationCenter: NotificationCenter
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: (any NSObjectProtocol)?

    @MainActor
    init?(handler: @escaping @MainActor () -> Void) {
        notificationCenter = NSWorkspace.shared.notificationCenter
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { _ in
            MainActor.assumeIsolated { handler() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            if crossAppLocalInputRequiresInvalidation(event) { handler() }
            return event
        }
        guard globalMonitor != nil, localMonitor != nil else { stop(); return nil }
        activationObserver = notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { handler() } }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        globalMonitor = nil
        localMonitor = nil
        activationObserver = nil
    }

    deinit { stop() }
}

@MainActor
private final class NativeCrossAppTextInput: CrossAppTextInput {
    let application: AXUIElement
    let element: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    init(application: AXUIElement, element: AXUIElement, window: AXUIElement, pid: pid_t) {
        self.application = application
        self.element = element
        self.window = window
        self.pid = pid
    }

    func isSameInput(as other: any CrossAppTextInput) -> Bool {
        guard let other = other as? NativeCrossAppTextInput else { return false }
        return pid == other.pid && CFEqual(element, other.element) && CFEqual(window, other.window)
    }

    func readSnapshot() -> CrossAppInputSnapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), crossAppOrdinaryWritable(element),
              let text = crossAppAttribute(element, kAXValueAttribute) as? String,
              text.utf8.count <= 1_024 * 1_024,
              let selection = crossAppSelection(element) else { return nil }
        let snapshot = CrossAppInputSnapshot(text: text, selection: selection)
        guard snapshot.valid,
              let length = crossAppAttribute(element, kAXNumberOfCharactersAttribute),
              crossAppCharacterCountMatches(length, utf16Length: (text as NSString).length),
              let selected = crossAppAttribute(element, kAXSelectedTextAttribute) as? String,
              selected == (text as NSString).substring(with: selection),
              crossAppAttribute(element, kAXValueAttribute) as? String == text,
              crossAppSelection(element) == selection else { return nil }
        return snapshot
    }

    func observe(_ handler: @escaping @MainActor (CrossAppInputEvent) -> Void) -> (any CrossAppInputObservation)? {
        NativeCrossAppObservation(input: self, handler: handler)
    }

    func insertSelectedText(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), crossAppOrdinaryWritable(element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focus = crossAppElementAttribute(application, kAXFocusedUIElementAttribute), CFEqual(focus, element),
              let focusWindow = crossAppElementAttribute(focus, kAXWindowAttribute), CFEqual(focusWindow, window),
              AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}

private final class NativeCrossAppObservation: CrossAppInputObservation {
    private let handler: @MainActor (CrossAppInputEvent) -> Void
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, String)] = []

    @MainActor
    init?(input: NativeCrossAppTextInput, handler: @escaping @MainActor (CrossAppInputEvent) -> Void) {
        self.handler = handler
        let callback: AXObserverCallback = { _, _, name, pointer in
            guard let pointer else { return }
            let context = Unmanaged<NativeCrossAppObservation>.fromOpaque(pointer).takeUnretainedValue()
            let event: CrossAppInputEvent
            switch name as String {
            case kAXValueChangedNotification: event = .valueChanged
            case kAXSelectedTextChangedNotification: event = .selectionChanged
            case kAXUIElementDestroyedNotification: event = .destroyed
            default: event = .focusChanged
            }
            MainActor.assumeIsolated { context.handler(event) }
        }
        guard AXObserverCreate(input.pid, callback, &observer) == .success, let observer else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let required = [(input.application, kAXFocusedUIElementChangedNotification),
                        (input.application, kAXFocusedWindowChangedNotification),
                        (input.element, kAXValueChangedNotification),
                        (input.element, kAXSelectedTextChangedNotification),
                        (input.element, kAXUIElementDestroyedNotification),
                        (input.window, kAXUIElementDestroyedNotification)]
        for (element, notification) in required {
            guard AXUIElementSetMessagingTimeout(element, 0.25) == .success,
                  AXObserverAddNotification(observer, element, notification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()) == .success else { stop(); return nil }
            registrations.append((element, notification))
        }
    }

    nonisolated func stop() {
        if let observer {
            for (element, notification) in registrations {
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        registrations = []
    }

    deinit { stop() }
}

@MainActor
private func crossAppOrdinaryWritable(_ element: AXUIElement) -> Bool {
    guard let role = crossAppAttribute(element, kAXRoleAttribute) as? String,
          [kAXTextAreaRole, kAXTextFieldRole].contains(role),
          (crossAppAttribute(element, kAXEnabledAttribute) as? Bool) == true,
          AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return false }
    var subrole: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
    switch status {
    case .success:
        guard let value = subrole as? String, value != kAXSecureTextFieldSubrole else { return false }
    case .attributeUnsupported, .noValue: break
    default: return false
    }
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
        && settable.boolValue
}

@MainActor
private func crossAppAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    guard AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return nil }
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

@MainActor
private func crossAppElementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = crossAppAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let result = unsafeDowncast(value, to: AXUIElement.self)
    guard AXUIElementSetMessagingTimeout(result, 0.25) == .success else { return nil }
    return result
}

@MainActor
private func crossAppSelection(_ element: AXUIElement) -> NSRange? {
    guard let value = crossAppAttribute(element, kAXSelectedTextRangeAttribute),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    var range = CFRange()
    guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
          range.location >= 0, range.length >= 0 else { return nil }
    return NSRange(location: range.location, length: range.length)
}
