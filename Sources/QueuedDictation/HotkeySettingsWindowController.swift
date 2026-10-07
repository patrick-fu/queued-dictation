import AppKit
import DictationCore

private enum HotkeyUITheme {
    static let pageBackground = NSColor(red: 248/255, green: 249/255, blue: 251/255, alpha: 1.0) // #F8F9FB
    static let cardBackground = NSColor.white
    static let primaryText = NSColor(red: 36/255, green: 41/255, blue: 54/255, alpha: 1.0) // #242936
    static let secondaryText = NSColor(red: 133/255, green: 141/255, blue: 156/255, alpha: 1.0) // #858D9C
    static let border = NSColor(red: 229/255, green: 231/255, blue: 237/255, alpha: 1.0) // #E5E7ED
    static let accent = NSColor(red: 44/255, green: 98/255, blue: 239/255, alpha: 1.0) // #2C62EF
    static let accentLight = NSColor(red: 245/255, green: 248/255, blue: 255/255, alpha: 1.0)
    static let pillBackground = NSColor(red: 245/255, green: 246/255, blue: 249/255, alpha: 1.0)
}

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
    private let keycapView = HotkeyKeycapView()
    private let pillButton = HotkeyPillButton(title: "点击上方按钮修改")
    private let tapCard = HotkeyGestureCardView(
        title: "短按",
        subtitle: "按一下开始说话，再按一下结束",
        badgeText: "点按录音模式"
    )
    private let holdCard = HotkeyGestureCardView(
        title: "长按",
        subtitle: "按住说话，松开结束",
        badgeText: "长按录音模式"
    )
    private var combination = HotkeyCombination.suggested

    init(session: HotkeyApplicationSession) {
        self.session = session
        let controller = session.controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "录音快捷键"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 640)
        window.delegate = self
        window.backgroundColor = HotkeyUITheme.pageBackground
        window.center()

        if case .combination(let saved) = controller.configuration.binding { combination = saved }

        bindingPopup.addItems(withTitles: ["Fn / Globe（推荐）", "自定义组合键"])
        gesturePopup.addItems(withTitles: ["点按开始，再按结束", "按住录音，松开结束"])
        bindingPopup.target = self
        bindingPopup.action = #selector(changeSelection)
        gesturePopup.target = self
        gesturePopup.action = #selector(changeSelection)

        editButton.target = self
        editButton.action = #selector(beginShortcutEntry)
        editButton.bezelStyle = .rounded
        editButton.font = .systemFont(ofSize: 13, weight: .medium)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.stringValue = session.configurationError ?? ""

        shortcut.onEditingChange = { [weak self] active in
            self?.session.setShortcutEntryActive(active)
            if !active { self?.render() }
        }
        shortcut.onCombination = { [weak self] in
            guard let self else { return }
            self.apply(.init(binding: .combination($0), gesture: self.controller.configuration.gesture))
        }
        shortcut.onInvalid = { [weak self] in self?.errorLabel.stringValue = $0 }

        keycapView.onClick = { [weak self] in self?.beginShortcutEntry() }
        pillButton.onClick = { [weak self] in self?.beginShortcutEntry() }

        tapCard.onSelect = { [weak self] in
            guard let self else { return }
            self.gesturePopup.selectItem(at: 0)
            self.changeSelection()
        }
        holdCard.onSelect = { [weak self] in
            guard let self else { return }
            self.gesturePopup.selectItem(at: 1)
            self.changeSelection()
        }

        // 顶层页面标题
        let title = NSTextField(labelWithString: "在任意输入框使用语音")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = HotkeyUITheme.primaryText

        // 上方中心大 Fn 键帽（180×76）与药丸修改按钮
        let keycapCenterStack = NSStackView(views: [keycapView, pillButton])
        keycapCenterStack.orientation = .vertical
        keycapCenterStack.alignment = .centerX
        keycapCenterStack.spacing = 10
        keycapCenterStack.translatesAutoresizingMaskIntoConstraints = false

        let keycapRow = NSView()
        keycapRow.translatesAutoresizingMaskIntoConstraints = false
        keycapRow.addSubview(keycapCenterStack)
        NSLayoutConstraint.activate([
            keycapCenterStack.centerXAnchor.constraint(equalTo: keycapRow.centerXAnchor),
            keycapCenterStack.topAnchor.constraint(equalTo: keycapRow.topAnchor),
            keycapCenterStack.bottomAnchor.constraint(equalTo: keycapRow.bottomAnchor)
        ])

        // 双卡等宽并排
        let gestureCardsStack = NSStackView(views: [tapCard, holdCard])
        gestureCardsStack.orientation = .horizontal
        gestureCardsStack.distribution = .fillEqually
        gestureCardsStack.spacing = 16
        gestureCardsStack.translatesAutoresizingMaskIntoConstraints = false

        // 快捷键设置与组合键录入卡片
        let bindingCard = HotkeyCardView(cornerRadius: 16)
        let bindingCardTitle = NSTextField(labelWithString: "快捷键配置")
        bindingCardTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        bindingCardTitle.textColor = HotkeyUITheme.primaryText

        let bindingRow = NSStackView(views: [NSTextField(labelWithString: "按键类型"), bindingPopup])
        bindingRow.orientation = .horizontal
        bindingRow.alignment = .centerY
        bindingRow.spacing = 12

        let shortcutRow = NSStackView(views: [shortcut, editButton])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 10

        let bindingStack = NSStackView(views: [bindingCardTitle, bindingRow, shortcutRow, errorLabel])
        bindingStack.orientation = .vertical
        bindingStack.alignment = .leading
        bindingStack.spacing = 14
        bindingStack.translatesAutoresizingMaskIntoConstraints = false
        bindingCard.addSubview(bindingStack)

        NSLayoutConstraint.activate([
            bindingStack.leadingAnchor.constraint(equalTo: bindingCard.leadingAnchor, constant: 22),
            bindingStack.trailingAnchor.constraint(equalTo: bindingCard.trailingAnchor, constant: -22),
            bindingStack.topAnchor.constraint(equalTo: bindingCard.topAnchor, constant: 20),
            bindingStack.bottomAnchor.constraint(equalTo: bindingCard.bottomAnchor, constant: -20),
            shortcutRow.widthAnchor.constraint(equalTo: bindingStack.widthAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 110),
            editButton.heightAnchor.constraint(equalToConstant: 36),
            bindingPopup.heightAnchor.constraint(equalToConstant: 36)
        ])

        // 系统状态与权限卡片
        let systemCard = HotkeyCardView(cornerRadius: 16)
        let systemCardTitle = NSTextField(labelWithString: "监听状态与系统权限")
        systemCardTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        systemCardTitle.textColor = HotkeyUITheme.primaryText

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = HotkeyUITheme.primaryText

        systemLabel.font = .systemFont(ofSize: 12)
        systemLabel.textColor = HotkeyUITheme.secondaryText

        let help = NSTextField(wrappingLabelWithString: "录音中可按 Esc 取消当前片段；Fn 系统操作由你在系统设置中核对。组合键按 Apple 物理键位识别，录入期间暂停快捷键监听。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = HotkeyUITheme.secondaryText

        let permissions = makeActionButton(title: "输入监控设置…", action: #selector(openListeningSettings))
        let keyboard = makeActionButton(title: "系统键盘设置…", action: #selector(openKeyboardSettings))
        let recheck = makeActionButton(title: "重新检查监听", action: #selector(recheckStatus))
        let buttonRow = NSStackView(views: [permissions, keyboard, recheck])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let systemStack = NSStackView(views: [systemCardTitle, statusLabel, systemLabel, help, buttonRow])
        systemStack.orientation = .vertical
        systemStack.alignment = .leading
        systemStack.spacing = 14
        systemStack.translatesAutoresizingMaskIntoConstraints = false
        systemCard.addSubview(systemStack)

        NSLayoutConstraint.activate([
            systemStack.leadingAnchor.constraint(equalTo: systemCard.leadingAnchor, constant: 22),
            systemStack.trailingAnchor.constraint(equalTo: systemCard.trailingAnchor, constant: -22),
            systemStack.topAnchor.constraint(equalTo: systemCard.topAnchor, constant: 20),
            systemStack.bottomAnchor.constraint(equalTo: systemCard.bottomAnchor, constant: -20),
            statusLabel.widthAnchor.constraint(equalTo: systemStack.widthAnchor),
            systemLabel.widthAnchor.constraint(equalTo: systemStack.widthAnchor),
            help.widthAnchor.constraint(equalTo: systemStack.widthAnchor)
        ])

        // 主纵向流式栈
        let mainStack = NSStackView(views: [title, keycapRow, gestureCardsStack, bindingCard, systemCard])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // 嵌入滚动容器
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView
        documentView.addSubview(mainStack)

        let content = window.contentView!
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: mainStack.bottomAnchor, constant: 24),

            mainStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),

            keycapRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            keycapView.widthAnchor.constraint(equalToConstant: 180),
            keycapView.heightAnchor.constraint(equalToConstant: 76),
            gestureCardsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            bindingCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            systemCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            shortcut.heightAnchor.constraint(equalToConstant: 38)
        ])

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
        gesturePopup.selectItem(at: configuration.gesture == .tapToToggle ? 0 : 1)

        let keyText = configuration.binding == .fn ? "Fn" : combination.displayName
        keycapView.label.stringValue = keyText
        keycapView.setAccessibilityValue(keyText)

        editButton.isEnabled = configuration.binding != .fn
        shortcut.isEnabled = configuration.binding != .fn || shortcut.isEditing
        shortcut.setCombination(combination)

        tapCard.setSelected(configuration.gesture == .tapToToggle)
        holdCard.setSelected(configuration.gesture == .holdToRecord)

        let status = controller.listenerStatus
        let recording: String
        switch status.recording {
        case .ready:
            recording = configuration.binding == .fn
                ? "Fn / Globe 快捷键已就绪"
                : "自定义组合键（\(combination.displayName)）已注册"
        case .inactive:
            recording = "快捷键监听已暂停"
        case .unavailable(let reason):
            recording = reason
        }

        let cancellation: String
        if case .unavailable(let reason) = status.cancellation {
            cancellation = "\n\(reason)"
        } else {
            cancellation = ""
        }

        statusLabel.stringValue = (session.configurationError.map { $0 + "\n快捷键暂停；App 录音入口仍可使用。\n" } ?? "") + recording + cancellation

        let permission = status.listenPermissionGranted ? "已允许" : "未获准（尚未允许、拒绝或已撤销）"
        let fnAction: String
        if status.systemFn.globeAction == 0 {
            fnAction = "不执行操作（推荐）"
        } else if status.systemFn.globeAction != nil {
            fnAction = "已绑定系统操作，请在键盘设置核对"
        } else {
            fnAction = "未能读取，请在键盘设置核对"
        }

        let standard: String
        switch status.systemFn.usesStandardFunctionKeys {
        case true?:
            standard = "使用标准功能键 (F1–F12)"
        case false?:
            standard = "使用系统功能 (亮度/音量等)"
        case nil:
            standard = "未能读取功能键设置"
        }

        systemLabel.stringValue = "系统输入监控权限：\(permission)\n系统 Fn / Globe 设置：\(fnAction)；\(standard)"
    }

    func windowWillClose(_ notification: Notification) { shortcut.stopEditing() }
    func windowDidResignKey(_ notification: Notification) { shortcut.stopEditing() }
    func endEditing() { shortcut.stopEditing() }

    @objc private func changeSelection() {
        let binding: HotkeyBinding = bindingPopup.indexOfSelectedItem == 0 ? .fn : .combination(combination)
        let gesture: HotkeyGesture = gesturePopup.indexOfSelectedItem == 0 ? .tapToToggle : .holdToRecord
        shortcut.stopEditing()
        apply(.init(binding: binding, gesture: gesture))
    }

    @objc private func beginShortcutEntry() {
        errorLabel.stringValue = ""
        shortcut.isEnabled = true
        if shortcut.window?.makeFirstResponder(shortcut) != true { render() }
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
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
        render()
    }

    private func makeActionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }
}

@MainActor
private class HotkeyCardView: NSView {
    init(cornerRadius: CGFloat = 16, backgroundColor: NSColor = HotkeyUITheme.cardBackground) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = HotkeyUITheme.border.cgColor
        layer?.backgroundColor = backgroundColor.cgColor
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class HotkeyKeycapView: NSControl {
    private let iconView = NSImageView()
    let label = NSTextField(labelWithString: "Fn")
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = HotkeyUITheme.border.cgColor
        layer?.backgroundColor = HotkeyUITheme.cardBackground.cgColor
        layer?.shadowColor = NSColor(red: 36/255, green: 41/255, blue: 54/255, alpha: 0.08).cgColor
        layer?.shadowOpacity = 1.0
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 6

        iconView.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "快捷键")
        iconView.contentTintColor = HotkeyUITheme.secondaryText
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = HotkeyUITheme.primaryText
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("快捷键修改")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        onClick()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        _ = accessibilityPerformPress()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class HotkeyPillButton: NSControl {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "点击上方按钮修改")
    var onClick: (() -> Void)?

    init(title: String = "点击上方按钮修改") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.borderColor = HotkeyUITheme.border.cgColor
        layer?.backgroundColor = HotkeyUITheme.pillBackground.cgColor

        iconView.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        iconView.contentTintColor = HotkeyUITheme.secondaryText
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = HotkeyUITheme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconView, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        onClick()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        _ = accessibilityPerformPress()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class HotkeyGestureCardView: NSControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let radioIndicator = NSView()
    private let radioInner = NSView()
    var onSelect: (() -> Void)?
    private(set) var isSelected: Bool = false

    init(title: String, subtitle: String, badgeText: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = HotkeyUITheme.border.cgColor
        layer?.backgroundColor = HotkeyUITheme.cardBackground.cgColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = HotkeyUITheme.primaryText

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = HotkeyUITheme.secondaryText
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        badgeLabel.stringValue = badgeText
        badgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        badgeLabel.textColor = HotkeyUITheme.secondaryText

        radioIndicator.wantsLayer = true
        radioIndicator.layer?.cornerRadius = 9
        radioIndicator.layer?.borderWidth = 1.5
        radioIndicator.layer?.borderColor = HotkeyUITheme.border.cgColor
        radioIndicator.layer?.backgroundColor = NSColor.clear.cgColor
        radioIndicator.translatesAutoresizingMaskIntoConstraints = false

        radioInner.wantsLayer = true
        radioInner.layer?.cornerRadius = 4.5
        radioInner.layer?.backgroundColor = HotkeyUITheme.accent.cgColor
        radioInner.translatesAutoresizingMaskIntoConstraints = false
        radioInner.isHidden = true
        radioIndicator.addSubview(radioInner)

        let headerRow = NSStackView(views: [titleLabel, NSView(), radioIndicator])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [headerRow, subtitleLabel, badgeLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.setCustomSpacing(12, after: subtitleLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            radioIndicator.widthAnchor.constraint(equalToConstant: 18),
            radioIndicator.heightAnchor.constraint(equalToConstant: 18),
            radioInner.centerXAnchor.constraint(equalTo: radioIndicator.centerXAnchor),
            radioInner.centerYAnchor.constraint(equalTo: radioIndicator.centerYAnchor),
            radioInner.widthAnchor.constraint(equalToConstant: 9),
            radioInner.heightAnchor.constraint(equalToConstant: 9),

            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(0)
        setAccessibilityLabel("\(title)，\(subtitle)")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        setAccessibilityValue(selected ? 1 : 0)
        updateAppearance()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.borderColor = HotkeyUITheme.accent.cgColor
            layer?.borderWidth = 1.5
            layer?.backgroundColor = HotkeyUITheme.accentLight.cgColor
            radioIndicator.layer?.borderColor = HotkeyUITheme.accent.cgColor
            radioInner.isHidden = false
            badgeLabel.textColor = HotkeyUITheme.accent
        } else {
            layer?.borderColor = HotkeyUITheme.border.cgColor
            layer?.borderWidth = 1.0
            layer?.backgroundColor = HotkeyUITheme.cardBackground.cgColor
            radioIndicator.layer?.borderColor = HotkeyUITheme.border.cgColor
            radioInner.isHidden = true
            badgeLabel.textColor = HotkeyUITheme.secondaryText
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onSelect else { return false }
        onSelect()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        _ = accessibilityPerformPress()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            onSelect?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class HotkeyCaptureView: NSView {
    var onEditingChange: ((Bool) -> Void)?
    var onCombination: ((HotkeyCombination) -> Void)?
    var onInvalid: ((String) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var editing = false
    var isEditing: Bool { editing }
    private var combination = HotkeyCombination.suggested
    override var acceptsFirstResponder: Bool { true }
    var isEnabled: Bool = true {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.6
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = HotkeyUITheme.border.cgColor
        layer?.backgroundColor = HotkeyUITheme.pillBackground.cgColor
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.textColor = HotkeyUITheme.primaryText
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
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
        guard isEnabled else { return false }
        editing = true
        label.stringValue = "按下组合键（Esc 退出）"
        layer?.borderColor = HotkeyUITheme.accent.cgColor
        layer?.backgroundColor = HotkeyUITheme.accentLight.cgColor
        onEditingChange?(true)
        return true
    }
    override func resignFirstResponder() -> Bool { finishEditing(); return true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
    }
    func stopEditing() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        finishEditing()
    }
    private func finishEditing() {
        guard editing else { return }
        editing = false
        label.stringValue = combination.displayName
        layer?.borderColor = HotkeyUITheme.border.cgColor
        layer?.backgroundColor = HotkeyUITheme.pillBackground.cgColor
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
