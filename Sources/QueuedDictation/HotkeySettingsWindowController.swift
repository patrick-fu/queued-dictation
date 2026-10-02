import AppKit
import DictationCore

@MainActor
final class HotkeySettingsWindowController: NSWindowController, NSWindowDelegate {
    private let session: HotkeyApplicationSession
    private var controller: HotkeyRecordingController { session.controller }
    private let bindingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gesturePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcut = HotkeyCaptureView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let systemLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "录入组合键…", target: nil, action: nil)
    private var combination = HotkeyCombination.suggested

    init(session: HotkeyApplicationSession) {
        self.session = session
        let controller = session.controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "录音快捷键"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 640)
        window.delegate = self
        window.center()
        if case .combination(let saved) = controller.configuration.binding { combination = saved }
        bindingPopup.addItems(withTitles: ["Fn / Globe", "自定义组合键"])
        gesturePopup.addItems(withTitles: ["按住录音，松开结束", "点按开始，再按结束"])
        bindingPopup.target = self
        bindingPopup.action = #selector(changeSelection)
        gesturePopup.target = self
        gesturePopup.action = #selector(changeSelection)
        editButton.target = self
        editButton.action = #selector(beginShortcutEntry)
        errorLabel.textColor = .systemRed
        errorLabel.stringValue = session.configurationError ?? ""
        shortcut.onEditingChange = { [weak session] in session?.setShortcutEntryActive($0) }
        shortcut.onCombination = { [weak self] in
            guard let self else { return }
            self.apply(.init(binding: .combination($0), gesture: self.controller.configuration.gesture))
        }
        shortcut.onInvalid = { [weak self] in self?.errorLabel.stringValue = $0 }
        let title = NSTextField(labelWithString: "在其他 App 中控制录音")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let permissions = NSButton(title: "输入监控设置…", target: self, action: #selector(openListeningSettings))
        let keyboard = NSButton(title: "系统键盘设置…", target: self, action: #selector(openKeyboardSettings))
        let recheck = NSButton(title: "重新检查监听", target: self, action: #selector(recheckStatus))
        let buttons = NSStackView(views: [permissions, keyboard, recheck])
        buttons.spacing = 10
        let help = NSTextField(wrappingLabelWithString: "录音中可按 Esc 取消当前片段；注册失败时使用 App 的取消按钮。组合键按 Apple 物理键位显示，录入期间暂停快捷键触发。Fn 系统操作由你在系统设置中选择。")
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, row("入口", bindingPopup), row("手势", gesturePopup), shortcut,
                                       editButton, statusLabel, systemLabel, help, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            shortcut.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcut.heightAnchor.constraint(equalToConstant: 44)
        ])
        for label in [statusLabel, systemLabel, help, errorLabel] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        render()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        controller.refreshListenerStatus()
        render()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func render() {
        let configuration = controller.configuration
        if case .combination(let saved) = configuration.binding { combination = saved }
        bindingPopup.selectItem(at: configuration.binding == .fn ? 0 : 1)
        gesturePopup.selectItem(at: configuration.gesture == .holdToRecord ? 0 : 1)
        editButton.isEnabled = configuration.binding != .fn
        shortcut.setCombination(combination)
        let status = controller.listenerStatus
        let recording: String
        switch status.recording {
        case .ready:
            recording = configuration.binding == .fn
                ? "Fn 监听已启动；实体 Fn / Globe 触发仍需实机检查。"
                : "组合键已注册。"
        case .inactive: recording = "快捷键监听已暂停。"
        case .unavailable(let reason): recording = reason
        }
        let cancellation: String
        if case .unavailable(let reason) = status.cancellation { cancellation = "\n\(reason)" }
        else { cancellation = "" }
        statusLabel.stringValue = (session.configurationError.map { $0 + "\n快捷键暂停；App 录音入口仍可使用。\n" } ?? "") + recording + cancellation
        let permission = status.listenPermissionGranted ? "系统预检已允许" : "未获准（尚未允许、拒绝或已撤销）"
        let fnAction: String
        if status.systemFn.globeAction == 0 { fnAction = "不执行操作" }
        else if status.systemFn.globeAction != nil { fnAction = "已绑定系统操作，请在键盘设置核对" }
        else { fnAction = "未能读取，请在键盘设置核对" }
        let standard: String
        switch status.systemFn.usesStandardFunctionKeys {
        case true?: standard = "使用标准 F1 / F2 等功能键"
        case false?: standard = "使用亮度、音量等系统功能"
        case nil: standard = "未能读取 F1 / F2 设置"
        }
        systemLabel.stringValue = "输入监控：\(permission)\n系统 Fn / Globe：\(fnAction)；\(standard)"
    }

    func windowWillClose(_ notification: Notification) { shortcut.stopEditing() }
    func windowDidResignKey(_ notification: Notification) { shortcut.stopEditing() }

    @objc private func changeSelection() {
        shortcut.stopEditing()
        let binding: HotkeyBinding = bindingPopup.indexOfSelectedItem == 0 ? .fn : .combination(combination)
        let gesture: HotkeyGesture = gesturePopup.indexOfSelectedItem == 0 ? .holdToRecord : .tapToToggle
        apply(.init(binding: binding, gesture: gesture))
    }

    @objc private func beginShortcutEntry() {
        errorLabel.stringValue = ""
        window?.makeFirstResponder(shortcut)
    }

    @objc private func openListeningSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
    @objc private func recheckStatus() {
        controller.retryShortcutRegistration()
        render()
    }

    private func apply(_ configuration: HotkeyConfiguration) {
        do {
            try session.saveConfiguration(configuration)
            errorLabel.stringValue = ""
        } catch { errorLabel.stringValue = error.localizedDescription }
        render()
    }

    private func row(_ title: String, _ view: NSView) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: title), view])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }
}

@MainActor
private final class HotkeyCaptureView: NSView {
    var onEditingChange: ((Bool) -> Void)?
    var onCombination: ((HotkeyCombination) -> Void)?
    var onInvalid: ((String) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var editing = false
    private var combination = HotkeyCombination.suggested
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setCombination(combination)
    }
    required init?(coder: NSCoder) { nil }

    func setCombination(_ combination: HotkeyCombination) {
        self.combination = combination
        if !editing { label.stringValue = combination.displayName }
    }

    override func becomeFirstResponder() -> Bool {
        editing = true
        label.stringValue = "按下组合键（Esc 退出）"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        onEditingChange?(true)
        return true
    }
    override func resignFirstResponder() -> Bool { finishEditing(); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    func stopEditing() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        finishEditing()
    }
    private func finishEditing() {
        guard editing else { return }
        editing = false
        label.stringValue = combination.displayName
        layer?.borderColor = NSColor.separatorColor.cgColor
        onEditingChange?(false)
    }
    override func keyDown(with event: NSEvent) {
        guard editing, !event.isARepeat else { return }
        var modifiers: HotkeyModifiers = []
        for (flag, modifier) in [(NSEvent.ModifierFlags.command, HotkeyModifiers.command), (.shift, .shift), (.option, .option), (.control, .control)] {
            if event.modifierFlags.contains(flag) { modifiers.insert(modifier) }
        }
        if event.keyCode == 53, modifiers.isEmpty { stopEditing(); return }
        let candidate = HotkeyCombination(keyCode: event.keyCode, modifiers: modifiers)
        if let reason = candidate.validationMessage { onInvalid?(reason); return }
        onCombination?(candidate)
        stopEditing()
    }
}
