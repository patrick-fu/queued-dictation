import Foundation

public struct HotkeyModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
}

public struct HotkeyCombination: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: HotkeyModifiers
    public init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    public static let suggested = Self(keyCode: 46, modifiers: [.command, .shift])

    public var validationMessage: String? {
        guard Self.keyNames[keyCode] != nil else {
            return "该按键不支持组合键录音，请选择普通按键与修饰键。"
        }
        guard !modifiers.isEmpty else { return "组合键需要至少一个 Command、Option、Control 或 Shift 修饰键。" }
        guard modifiers.rawValue & ~UInt32(15) == 0 else { return "该修饰键不支持组合键录音。" }
        return nil
    }

    public var displayName: String {
        var prefix = ""
        for (modifier, symbol) in [(HotkeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if modifiers.contains(modifier) { prefix += symbol }
        }
        return prefix + (Self.keyNames[keyCode] ?? "不支持的按键")
    }

    // 保存物理虚拟键码；字符名称按 Apple ANSI/JIS 键位显示，不随输入法变更注册。
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        64: "F17", 65: "小键盘 .", 67: "小键盘 ×", 69: "小键盘 +", 71: "Clear", 75: "小键盘 /", 76: "小键盘 Enter",
        78: "小键盘 −", 79: "F18", 80: "F19", 81: "小键盘 =", 82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2",
        85: "小键盘 3", 86: "小键盘 4", 87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7", 90: "F20", 91: "小键盘 8",
        92: "小键盘 9", 93: "¥", 94: "_", 95: "小键盘 ,", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 102: "英数", 103: "F11", 104: "かな", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

public enum HotkeyBinding: Codable, Equatable, Sendable {
    case fn
    case combination(HotkeyCombination)
}

public enum HotkeyGesture: String, Codable, Sendable {
    case holdToRecord, tapToToggle
}

public struct HotkeyConfiguration: Codable, Equatable, Sendable {
    public var binding: HotkeyBinding
    public var gesture: HotkeyGesture
    public init(binding: HotkeyBinding = .fn, gesture: HotkeyGesture = .holdToRecord) {
        self.binding = binding
        self.gesture = gesture
    }
}

public enum HotkeyEvent: Equatable, Sendable {
    case pressed(HotkeyBinding, isRepeat: Bool)
    case released(HotkeyBinding)
    case cancelCurrentRecording
}

public enum HotkeyAvailability: Equatable, Sendable {
    case ready, inactive
    case unavailable(String)
}

public struct HotkeySystemFnSettings: Equatable, Sendable {
    public let globeAction: Int?
    public let usesStandardFunctionKeys: Bool?
    public init(globeAction: Int? = nil, usesStandardFunctionKeys: Bool? = nil) {
        self.globeAction = globeAction
        self.usesStandardFunctionKeys = usesStandardFunctionKeys
    }
}

public struct HotkeyListenerStatus: Equatable, Sendable {
    public var recording: HotkeyAvailability
    public var cancellation: HotkeyAvailability
    public var listenPermissionGranted: Bool
    public var systemFn: HotkeySystemFnSettings
    public init(recording: HotkeyAvailability, cancellation: HotkeyAvailability,
                listenPermissionGranted: Bool, systemFn: HotkeySystemFnSettings) {
        self.recording = recording
        self.cancellation = cancellation
        self.listenPermissionGranted = listenPermissionGranted
        self.systemFn = systemFn
    }
}

@MainActor
public protocol GlobalHotkeyListening: AnyObject {
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
    var onStatusChange: (() -> Void)? { get set }
    var status: HotkeyListenerStatus { get }
    func configure(_ binding: HotkeyBinding)
    func setCancellationEnabled(_ enabled: Bool)
    func setSuspended(_ suspended: Bool)
    func refreshStatus()
    func invalidate()
}
