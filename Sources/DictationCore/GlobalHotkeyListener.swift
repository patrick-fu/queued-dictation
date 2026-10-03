import Carbon
import CoreGraphics
import Foundation

@MainActor
public final class GlobalHotkeyListener: GlobalHotkeyListening {
    public var onEvent: ((HotkeyEvent) -> Void)?
    public var onStatusChange: (() -> Void)?
    public private(set) var status = HotkeyListenerStatus(recording: .inactive, cancellation: .inactive,
                                                         listenPermissionGranted: false, systemFn: .init())
    private let resources = HotkeyNativeResources()
    private var binding: HotkeyBinding?
    private var suspended = false
    private var invalidated = false
    private var cancellationRequested = false
    private var nextIdentifier: UInt32 = 0
    private var recordingIdentifier: UInt32?
    private var cancellationIdentifier: UInt32?
    private var fnHeld = false
    private var combinationHeld = false
    private var escapeHeld = false
#if NATIVE_ACCEPTANCE
    private let nativeTrace = NativeAcceptanceTrace.shared
    fileprivate var nativeStamp: NativeHotkeyStamp?
    private func traceHotkey(_ binding: String, down: Bool, accepted: Bool, repeated: Bool) {
        guard let stamp = nativeStamp else { nativeTrace?.fail("missing_hotkey_payload"); return }
        nativeTrace?.hotkey(binding: binding, edge: down ? "down" : "up", accepted: accepted, isRepeat: repeated, stamp: stamp)
    }
#endif
    private static let signature: OSType = 0x5144484B

    public init() { readSystemStatus() }

    public func configure(_ binding: HotkeyBinding) {
        guard !invalidated else { return }
        let previous = status
        self.binding = binding
        resources.clearRecording()
        recordingIdentifier = nil
        readSystemStatus()
        if suspended { status.recording = .inactive }
        else {
            switch binding {
            case .fn: installFnListener()
            case .combination(let combination): installCombination(combination)
            }
        }
        updateCancellation()
        publishChange(from: previous)
    }

    public func setCancellationEnabled(_ enabled: Bool) {
        guard !invalidated, cancellationRequested != enabled else { return }
        let previous = status
        cancellationRequested = enabled
        updateCancellation()
        publishChange(from: previous)
    }

    public func setSuspended(_ suspended: Bool) {
        guard !invalidated, self.suspended != suspended else { return }
        self.suspended = suspended
        if let binding { configure(binding) }
    }

    public func refreshStatus() {
        guard !invalidated else { return }
        let previous = status
        readSystemStatus()
        if binding == .fn, !suspended {
            if !status.listenPermissionGranted {
                resources.clearRecording()
                status.recording = .unavailable(Self.permissionMessage)
            } else if let tap = resources.fnTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    status.recording = .unavailable("Fn 监听已中断。请重新选择快捷键，或使用组合键／App 录音入口。")
                    resources.clearRecording()
                }
            } else if !previous.listenPermissionGranted {
                installFnListener()
            }
        }
        publishChange(from: previous)
    }

    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        let previous = status
        resources.clearAll()
        recordingIdentifier = nil
        cancellationIdentifier = nil
        status.recording = .inactive
        status.cancellation = .inactive
        publishChange(from: previous)
    }

    private static let permissionMessage = "Fn 监听未获准（尚未允许、拒绝或已撤销）。请在系统设置中允许输入监控，或改用组合键／App 录音入口。"

    private func installFnListener() {
        guard status.listenPermissionGranted else {
            status.recording = .unavailable(Self.permissionMessage)
            return
        }
        fnHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                         options: .listenOnly, eventsOfInterest: mask,
                                         callback: hotkeyFnTapCallback, userInfo: context),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            status.recording = .unavailable("无法建立 Fn 监听。请检查输入监控，或改用组合键／App 录音入口。")
            return
        }
        resources.fnTap = tap
        resources.fnSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) { status.recording = .ready }
        else {
            resources.clearRecording()
            status.recording = .unavailable("Fn 监听未启用，请改用组合键／App 录音入口。")
        }
    }

    private func installCombination(_ combination: HotkeyCombination) {
        if let reason = combination.validationMessage { status.recording = .unavailable(reason); return }
        let handlerStatus = ensureCarbonHandler()
        guard handlerStatus == noErr else {
            status.recording = .unavailable("无法安装组合键监听（系统错误 \(handlerStatus)），请使用 App 录音入口。")
            return
        }
        let identifier = makeIdentifier()
        var modifiers: UInt32 = 0
        for (modifier, flag) in [(HotkeyModifiers.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)] {
            if combination.modifiers.contains(modifier) { modifiers |= UInt32(flag) }
        }
        let result = RegisterEventHotKey(UInt32(combination.keyCode), modifiers,
                                        EventHotKeyID(signature: Self.signature, id: identifier),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &resources.recordingKey)
        if result == noErr, resources.recordingKey != nil {
            recordingIdentifier = identifier
            combinationHeld = CGEventSource.keyState(.combinedSessionState, key: combination.keyCode)
            status.recording = .ready
        } else {
            status.recording = .unavailable("组合键注册失败（系统错误 \(result)）。请选择其他组合键，或使用 App 录音入口。")
        }
    }

    private func updateCancellation() {
        if !cancellationRequested || suspended {
            resources.clearCancellation()
            cancellationIdentifier = nil
            status.cancellation = .inactive
            return
        }
        guard resources.cancellationKey == nil else { return }
        let handlerStatus = ensureCarbonHandler()
        guard handlerStatus == noErr else {
            status.cancellation = .unavailable("Esc 取消监听安装失败（系统错误 \(handlerStatus)）。请使用 App 的取消按钮。")
            return
        }
        let identifier = makeIdentifier()
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: identifier),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &resources.cancellationKey)
        if result == noErr, resources.cancellationKey != nil {
            cancellationIdentifier = identifier
            escapeHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
            status.cancellation = .ready
        } else {
            status.cancellation = .unavailable("Esc 取消注册失败（系统错误 \(result)）。请使用 App 的取消按钮。")
        }
    }

    private func ensureCarbonHandler() -> OSStatus {
        if resources.handler != nil { return noErr }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        return InstallEventHandler(GetApplicationEventTarget(), hotkeyCarbonCallback, events.count, &events,
                                   Unmanaged.passUnretained(self).toOpaque(), &resources.handler)
    }

    private func makeIdentifier() -> UInt32 { nextIdentifier &+= 1; return nextIdentifier }

    private func readSystemStatus() {
        status.listenPermissionGranted = CGPreflightListenEventAccess()
        let action = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? NSNumber
        let standard = (CFPreferencesCopyValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication,
                                               kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                        ?? CFPreferencesCopyValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication,
                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) as? NSNumber
        status.systemFn = .init(globeAction: action?.intValue, usesStandardFunctionKeys: standard?.boolValue)
    }

    private func publishChange(from previous: HotkeyListenerStatus) {
        if status != previous { onStatusChange?() }
    }

    fileprivate func receiveFn(_ type: CGEventType, keyCode: Int64, down: Bool) {
#if NATIVE_ACCEPTANCE
        let accepted = !invalidated && !suspended && binding == .fn && status.recording == .ready &&
            type == .flagsChanged && keyCode == Int64(kVK_Function) && down != fnHeld
        traceHotkey("fn", down: down, accepted: accepted, repeated: down && fnHeld)
#endif
        guard !invalidated, !suspended, binding == .fn else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let previous = status
            status.recording = .unavailable("Fn 监听已中断，当前录音将结束。可使用组合键／App 录音入口。")
            publishChange(from: previous)
            let interrupted = status
            readSystemStatus()
            if status.listenPermissionGranted, let tap = resources.fnTap {
                fnHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { status.recording = .ready }
            } else {
                resources.clearRecording()
                status.recording = .unavailable(Self.permissionMessage)
            }
            publishChange(from: interrupted)
            return
        }
        guard status.recording == .ready, type == .flagsChanged,
              keyCode == Int64(kVK_Function) else { return }
        guard down != fnHeld else { return }
        fnHeld = down
        onEvent?(down ? .pressed(.fn, isRepeat: false) : .released(.fn))
    }

    fileprivate func receiveCarbon(signature: OSType, identifier: UInt32, down: Bool) -> OSStatus {
#if NATIVE_ACCEPTANCE
        let recording = identifier == recordingIdentifier && status.recording == .ready
        let cancellation = identifier == cancellationIdentifier && status.cancellation == .ready
        let accepted = !invalidated && !suspended && signature == Self.signature && (recording || cancellation)
        let repeated = down && (recording ? combinationHeld : escapeHeld)
        traceHotkey(recording ? "combination" : "cancel", down: down, accepted: accepted && !repeated, repeated: repeated)
#endif
        guard !invalidated, !suspended else { return OSStatus(eventNotHandledErr) }
        guard signature == Self.signature else { return OSStatus(eventNotHandledErr) }
        if identifier == recordingIdentifier, let binding, status.recording == .ready {
            if down {
                let repeated = combinationHeld
                combinationHeld = true
                onEvent?(.pressed(binding, isRepeat: repeated))
            } else { combinationHeld = false; onEvent?(.released(binding)) }
            return noErr
        }
        if identifier == cancellationIdentifier, status.cancellation == .ready {
            if down, !escapeHeld { escapeHeld = true; onEvent?(.cancelCurrentRecording) }
            if !down { escapeHeld = false }
            return noErr
        }
        return OSStatus(eventNotHandledErr)
    }
}

private func hotkeyFnTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                 _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let context {
        // 该 tap 只加入主 RunLoop；同步保留按下／松开的顺序。
        let listener = Unmanaged<GlobalHotkeyListener>.fromOpaque(context).takeUnretainedValue()
        let keyCode = type == .flagsChanged ? event.getIntegerValueField(.keyboardEventKeycode) : 0
        let down = type == .flagsChanged && event.flags.contains(.maskSecondaryFn)
#if NATIVE_ACCEPTANCE
        let osTimestamp = event.timestamp
        let callbackNS = NativeAcceptanceTrace.shared?.clock.now() ?? 0
#endif
        MainActor.assumeIsolated {
#if NATIVE_ACCEPTANCE
            if let trace = NativeAcceptanceTrace.shared {
                listener.nativeStamp = trace.quartzStamp(osTimestamp, callback: callbackNS)
            }
#endif
            listener.receiveFn(type, keyCode: keyCode, down: down)
        }
    }
    return Unmanaged.passUnretained(event)
}

private func hotkeyCarbonCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                  _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    let listener = Unmanaged<GlobalHotkeyListener>.fromOpaque(context).takeUnretainedValue()
    var id = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard result == noErr else { return OSStatus(eventNotHandledErr) }
    let signature = id.signature
    let identifier = id.id
    let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
#if NATIVE_ACCEPTANCE
    let osTimestamp = GetEventTime(event)
    let callbackNS = NativeAcceptanceTrace.shared?.clock.now() ?? 0
#endif
    return MainActor.assumeIsolated {
#if NATIVE_ACCEPTANCE
        if let trace = NativeAcceptanceTrace.shared {
            listener.nativeStamp = trace.carbonStamp(osTimestamp, callback: callbackNS)
        }
#endif
        return listener.receiveCarbon(signature: signature, identifier: identifier, down: down)
    }
}

private final class HotkeyNativeResources {
    var recordingKey: EventHotKeyRef?
    var cancellationKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var fnTap: CFMachPort?
    var fnSource: CFRunLoopSource?
    func clearRecording() {
        if let recordingKey { UnregisterEventHotKey(recordingKey) }
        recordingKey = nil
        if let fnSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), fnSource, .commonModes) }
        if let fnTap { CGEvent.tapEnable(tap: fnTap, enable: false); CFMachPortInvalidate(fnTap) }
        fnSource = nil
        fnTap = nil
    }
    func clearCancellation() {
        if let cancellationKey { UnregisterEventHotKey(cancellationKey) }
        cancellationKey = nil
    }
    func clearAll() {
        clearRecording()
        clearCancellation()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    deinit { clearAll() }
}
