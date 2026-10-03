import AppKit
import ApplicationServices
import CryptoKit

@MainActor
public final class TextEditDelivery: TextDelivering {
    private var targets: [UUID: ObservedTextTarget] = [:]
    private var inputMonitor: Any?
    public init() {}
    public var accessibilityAuthorized: Bool { AXIsProcessTrusted() }

    public func captureTarget() -> TextDeliveryTarget? {
        guard accessibilityAuthorized,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.TextEdit" else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementSetMessagingTimeout(application, 0.25) == .success else { return nil }
        guard let element = elementAttribute(application, kAXFocusedUIElementAttribute),
              let window = elementAttribute(element, kAXWindowAttribute), writable(element) else { return nil }
        let observed = ObservedTextTarget(application: application, element: element, window: window, pid: app.processIdentifier)
        observed.currentState = { [weak self] in
            guard let self, let text = self.textValue(element), let range = self.selection(element) else { return nil }
            return (Data(SHA256.hash(data: Data(text.utf8))), range)
        }
        guard observed.observe(), let text = textValue(element), let range = selection(element),
              range.location >= 0, range.length >= 0, range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location else { observed.stop(); return nil }
        observed.fingerprint = Data(SHA256.hash(data: Data(text.utf8)))
        observed.range = range
        let token = TextDeliveryTarget()
        targets[token.id] = observed
        if inputMonitor == nil {
            inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for pending in self.targets.values { pending.invalidated = true }
                }
            }
        }
        return token
    }

    public func deliver(_ text: String, to target: TextDeliveryTarget) -> TextDeliveryResult {
        guard let observed = targets[target.id], !observed.invalidated,
              accessibilityAuthorized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == observed.pid,
              let focused = elementAttribute(observed.application, kAXFocusedUIElementAttribute), CFEqual(focused, observed.element),
              let window = elementAttribute(focused, kAXWindowAttribute), CFEqual(window, observed.window),
              writable(focused), let current = textValue(focused), let range = selection(focused),
              range.location == observed.range.location, range.length == observed.range.length,
              Data(SHA256.hash(data: Data(current.utf8))) == observed.fingerprint,
              !observed.invalidated else { return .manual }
        let expected = (current as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        let expectedRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        let expectedFingerprint = Data(SHA256.hash(data: Data(expected.utf8)))
        let cohort = targets.values.filter {
            !$0.invalidated && $0.pid == observed.pid && CFEqual($0.element, observed.element) && CFEqual($0.window, observed.window)
                && $0.fingerprint == observed.fingerprint && $0.range.location == range.location && $0.range.length == range.length
        }
        for pending in cohort { pending.prepareSystemWrite(fingerprint: expectedFingerprint, range: expectedRange) }
        let status = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success else { cohort.forEach { $0.invalidated = true }; return .uncertain }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == observed.pid,
              let afterFocus = elementAttribute(observed.application, kAXFocusedUIElementAttribute), CFEqual(afterFocus, focused),
              textValue(focused) == expected, let afterRange = selection(focused),
              afterRange.location == expectedRange.location, afterRange.length == expectedRange.length,
              !observed.invalidated else { cohort.forEach { $0.invalidated = true }; return .uncertain }
        // 只有同一控件、同一旧快照且仍有效的等待目标能归因此次已验证的系统写入。
        for pending in cohort where !pending.invalidated { pending.fingerprint = expectedFingerprint; pending.range = expectedRange }
        return .delivered
    }

    public func insertAtCurrentCursor(_ text: String) -> TextDeliveryResult {
        guard let target = captureTarget() else { return .manual }
        defer { releaseTarget(target) }
        return deliver(text, to: target)
    }
    public func releaseTarget(_ target: TextDeliveryTarget) {
        targets.removeValue(forKey: target.id)?.stop()
        if targets.isEmpty, let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
    }
    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func writable(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole].contains(role),
              (attribute(element, kAXEnabledAttribute) as? Bool) == true,
              (attribute(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
    }
    private func textValue(_ element: AXUIElement) -> String? {
        guard let text = attribute(element, kAXValueAttribute) as? String, text.utf8.count <= 1_024 * 1_024 else { return nil }
        return text
    }
    private func selection(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = unsafeDowncast(value, to: AXUIElement.self)
        // AX 超时只属于此实例；返回的控件／窗口不会继承 application 对象的设置。
        guard AXUIElementSetMessagingTimeout(result, 0.25) == .success else { return nil }
        return result
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

@MainActor
private final class ObservedTextTarget {
    let application: AXUIElement
    let element: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    var range = CFRange()
    var fingerprint = Data()
    var invalidated = false
    var currentState: (() -> (Data, CFRange)?)?
    private var systemState: (Data, CFRange)?
    private var systemNotifications: [String: Int] = [:]
    private var systemWriteDeadline: TimeInterval = 0
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, String)] = []
    private var activationObserver: (any NSObjectProtocol)?
    init(application: AXUIElement, element: AXUIElement, window: AXUIElement, pid: pid_t) {
        self.application = application; self.element = element; self.window = window; self.pid = pid
    }
    func observe() -> Bool {
        let callback: AXObserverCallback = { _, _, notification, pointer in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                Unmanaged<ObservedTextTarget>.fromOpaque(pointer).takeUnretainedValue().changed(notification as String)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for (object, notification) in [(application, kAXFocusedUIElementChangedNotification),
                                        (application, kAXFocusedWindowChangedNotification),
                                        (element, kAXValueChangedNotification), (element, kAXSelectedTextChangedNotification),
                                        (element, kAXUIElementDestroyedNotification)] {
            guard AXObserverAddNotification(observer, object, notification as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success else {
                stop(); return false
            }
            registrations.append((object, notification))
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if activatedPID != self.pid { self.invalidated = true }
                }
            }
        return true
    }
    func prepareSystemWrite(fingerprint: Data, range: CFRange) {
        systemState = (fingerprint, range)
        let instant = ProcessInfo.processInfo.systemUptime
        if instant > systemWriteDeadline { systemNotifications = [:] }
        systemNotifications[kAXValueChangedNotification, default: 0] += 1
        systemNotifications[kAXSelectedTextChangedNotification, default: 0] += 1
        systemWriteDeadline = instant + 0.5
    }
    private func changed(_ notification: String) {
        if !invalidated, ProcessInfo.processInfo.systemUptime <= systemWriteDeadline,
           systemNotifications[notification, default: 0] > 0, let expected = systemState, let actual = currentState?(),
           actual.0 == expected.0, actual.1.location == expected.1.location, actual.1.length == expected.1.length {
            systemNotifications[notification, default: 0] -= 1
            return
        }
        invalidated = true
    }
    func stop() {
        if let observer {
            for (object, notification) in registrations { AXObserverRemoveNotification(observer, object, notification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        observer = nil; activationObserver = nil; registrations = []
    }
}
