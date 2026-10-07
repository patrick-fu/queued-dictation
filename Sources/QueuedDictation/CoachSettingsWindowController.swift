import AppKit
import DictationCore

@MainActor
final class CoachSettingsWindowController: NSWindowController, NSTextViewDelegate {
    private let scheduler: CoachWorkScheduler
    private let settings: CoachSettings
    private let services: ServiceSettings
    private let onOpenSharedServices: (() -> Void)?

    private let enabledSwitch = NSSwitch()
    private let servicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputModePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputHelp = NSTextField(wrappingLabelWithString: "")
    private let model = NSTextField()
    private let concurrency = NSTextField()
    private let timeout = NSTextField()
    private let corner = NSPopUpButton(frame: .zero, pullsDown: false)
    private let prompt = NSTextView()
    private let promptBadge = NSTextField(labelWithString: "默认提示词")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var sharedServices: [ModelService] = []
    private var usesDefaultPrompt = true

    init(scheduler: CoachWorkScheduler, settings: CoachSettings, services: ServiceSettings,
         onOpenSharedServices: (() -> Void)? = nil) {
        self.scheduler = scheduler
        self.settings = settings
        self.services = services
        self.onOpenSharedServices = onOpenSharedServices

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "英语带教"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 720)
        window.center()

        configureControls()

        let switchCard = makeSwitchCard()
        let modelCard = makeModelCard()
        let panelCard = makePanelCard()
        let promptCard = makePromptCard()

        let rootStack = NSStackView(views: [switchCard, modelCard, panelCard, promptCard])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 20
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        for card in [switchCard, modelCard, panelCard, promptCard] {
            card.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = CoachTheme.canvasBackground.cgColor
        content.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        loadSettings()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        loadSettings()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func textDidChange(_ notification: Notification) {
        usesDefaultPrompt = false
        updatePromptBadge()
    }

    @objc func synchronizeEnabled() {
        enabledSwitch.state = scheduler.configuration.enabled ? .on : .off
    }

    @objc private func enabledChanged() {
        do { try scheduler.setEnabled(enabledSwitch.state == .on) }
        catch { showFailure(error) }
        synchronizeEnabled()
    }

    func refreshSharedServices() {
        do {
            try refreshServiceChoices(selecting: servicePicker.selectedItem?.representedObject as? UUID)
            describeDestination()
        } catch {
            showFailure(error)
        }
    }

    private func refreshServiceChoices(selecting serviceID: UUID?) throws {
        sharedServices = try services.load().services
        servicePicker.removeAllItems()
        let unselected = NSMenuItem(title: "尚未选择", action: nil, keyEquivalent: "")
        servicePicker.menu?.addItem(unselected)
        for service in sharedServices {
            let item = NSMenuItem(title: service.name, action: nil, keyEquivalent: "")
            item.representedObject = service.id
            servicePicker.menu?.addItem(item)
        }
        servicePicker.select(servicePicker.itemArray.first { $0.representedObject as? UUID == serviceID } ?? unselected)
    }

    private func loadSettings() {
        do {
            let configuration = try settings.load()
            try refreshServiceChoices(selecting: configuration.role?.serviceID)
            model.stringValue = configuration.role?.model ?? ""
            inputModePicker.selectItem(at: CoachInputMode.allCases.firstIndex(of: configuration.inputMode) ?? 0)
            enabledSwitch.state = configuration.enabled ? .on : .off
            concurrency.stringValue = String(configuration.concurrency)
            timeout.stringValue = String(configuration.timeout)
            corner.selectItem(at: CoachCorner.allCases.firstIndex(of: configuration.corner) ?? 0)
            prompt.string = configuration.prompt
            usesDefaultPrompt = configuration.customPrompt == nil
            updatePromptBadge()
            describeDestination()
        } catch {
            showFailure(error)
        }
    }

    @objc private func saveSettings() {
        do {
            guard let count = Int(concurrency.stringValue), let seconds = TimeInterval(timeout.stringValue) else {
                throw CoachFailure.invalidConfiguration
            }
            let serviceID = servicePicker.selectedItem?.representedObject as? UUID
            let role = serviceID.map { ModelRoleConfiguration(serviceID: $0, model: model.stringValue) }
            guard CoachCorner.allCases.indices.contains(corner.indexOfSelectedItem) else { throw CoachFailure.invalidConfiguration }
            guard CoachInputMode.allCases.indices.contains(inputModePicker.indexOfSelectedItem) else { throw CoachFailure.invalidConfiguration }
            try settings.save(CoachConfiguration(enabled: scheduler.configuration.enabled, role: role, concurrency: count,
                timeout: seconds, customPrompt: usesDefaultPrompt ? nil : prompt.string,
                corner: CoachCorner.allCases[corner.indexOfSelectedItem],
                inputMode: CoachInputMode.allCases[inputModePicker.indexOfSelectedItem]))
            try scheduler.configurationChanged()
            describeDestination()
            status.textColor = CoachTheme.secondaryText
            status.stringValue = "已保存带教配置。"
        } catch {
            showFailure(error)
        }
    }

    @objc private func restorePrompt() {
        do {
            guard let mode = selectedInputMode else { throw CoachFailure.invalidConfiguration }
            var configuration = try settings.load()
            configuration.inputMode = mode
            configuration.customPrompt = nil
            try settings.save(configuration)
            prompt.string = configuration.prompt
            usesDefaultPrompt = true
            updatePromptBadge()
            try scheduler.configurationChanged()
            status.textColor = CoachTheme.secondaryText
            status.stringValue = "已恢复当前默认提示词。"
        } catch {
            showFailure(error)
        }
    }

    @objc private func serviceChanged() { describeDestination() }

    @objc private func inputModeChanged() {
        if usesDefaultPrompt, let mode = selectedInputMode {
            prompt.string = CoachConfiguration.defaultPrompt(for: mode)
        }
        describeDestination()
    }

    @objc private func openSharedServices() { onOpenSharedServices?() }

    private func describeDestination() {
        status.textColor = CoachTheme.secondaryText
        let audio = selectedInputMode == .originalAudio
        inputHelp.stringValue = audio
            ? "同时发送原始 WAV 音频与转写文本，由多模态模型评测流利度并给出具体时间依据。"
            : "仅发送未经润色的转写文本，分析语法与用词表达，不评测发音与流利度。"
        guard let id = servicePicker.selectedItem?.representedObject as? UUID,
              let service = sharedServices.first(where: { $0.id == id }) else {
            status.stringValue = "尚未选择带教服务；启用时会保留待发送带教，主输入继续。"
            return
        }
        status.stringValue = "服务节点：\(service.baseURL) · \(audio ? "发送原始音频与文本" : "仅发送文本") · 凭据从钥匙串读取"
    }

    private var selectedInputMode: CoachInputMode? {
        guard CoachInputMode.allCases.indices.contains(inputModePicker.indexOfSelectedItem) else { return nil }
        return CoachInputMode.allCases[inputModePicker.indexOfSelectedItem]
    }

    private func showFailure(_ error: Error) {
        status.textColor = .systemRed
        status.stringValue = (error as? CoachFailure)?.localizedDescription ?? "带教设置未能保存，请检查本机目录与共享服务配置。"
    }

    private func updatePromptBadge() {
        promptBadge.stringValue = usesDefaultPrompt ? "默认提示词" : "自定义提示词"
        promptBadge.textColor = usesDefaultPrompt ? CoachTheme.secondaryText : CoachTheme.primaryBlue
    }

    // MARK: - Control Configurations

    private func configureControls() {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged)
        enabledSwitch.controlSize = .regular

        servicePicker.target = self
        servicePicker.action = #selector(serviceChanged)
        stylePopUp(servicePicker)

        inputModePicker.addItems(withTitles: ["文本（无音频，不评流利度）", "原始音频和文本（可依据音频评流利度）"])
        inputModePicker.target = self
        inputModePicker.action = #selector(inputModeChanged)
        stylePopUp(inputModePicker)

        corner.addItems(withTitles: ["右下", "左下", "右上", "左上"])
        stylePopUp(corner)

        promptBadge.font = .systemFont(ofSize: 11, weight: .medium)
        inputHelp.font = .systemFont(ofSize: 12)
        inputHelp.textColor = CoachTheme.secondaryText
        status.font = .systemFont(ofSize: 12)
        status.textColor = CoachTheme.secondaryText
    }

    private func stylePopUp(_ popup: NSPopUpButton) {
        popup.bezelStyle = .regularSquare
        popup.isBordered = true
        popup.wantsLayer = true
        popup.layer?.cornerRadius = 8
        popup.layer?.borderWidth = 1
        popup.layer?.borderColor = CoachTheme.borderColor.cgColor
        popup.layer?.backgroundColor = CoachTheme.cardBackground.cgColor
        popup.font = .systemFont(ofSize: 13, weight: .regular)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    // MARK: - Card Builders

    private func makeSwitchCard() -> CoachCardView {
        let card = CoachCardView()

        let iconContainer = NSView()
        iconContainer.wantsLayer = true
        iconContainer.layer?.backgroundColor = CoachTheme.pillBackground.cgColor
        iconContainer.layer?.cornerRadius = 10
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconContainer.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let iconView = NSImageView(image: NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "英语带教")!)
        iconView.contentTintColor = CoachTheme.primaryBlue
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22)
        ])

        let titleLabel = NSTextField(labelWithString: "开启英语带教与卡片浮窗")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = CoachTheme.primaryText

        let subtitleLabel = NSTextField(wrappingLabelWithString: "语音输入时独立分析英语表达，实时提供发音、语法与表达改进建议")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = CoachTheme.secondaryText

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(iconContainer)
        card.addSubview(textStack)
        card.addSubview(enabledSwitch)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            iconContainer.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconContainer.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 18),
            iconContainer.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: enabledSwitch.leadingAnchor, constant: -16),

            enabledSwitch.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            enabledSwitch.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])

        return card
    }

    private func makeModelCard() -> CoachCardView {
        let card = CoachCardView()

        let header = makeCardHeader(
            icon: "cpu",
            title: "模型与服务设置",
            subtitle: "配置独立用于英语带教的共享服务、模型 ID 与并发策略"
        )

        let serviceGroup = makeFieldGroup(title: "共享服务", control: servicePicker, help: "提供带教模型推理的 API 节点")
        let modelBox = makeTextInputBox(field: model, placeholder: "所选服务中支持该输入方式的 Chat 模型 ID")
        let modelGroup = makeFieldGroup(title: "带教模型 ID", control: modelBox, help: "所选服务中支持 Chat / 多模态推理的模型")
        let row1 = makeTwoColumnRow(left: serviceGroup, right: modelGroup)

        let inputModeGroup = makeFieldGroup(title: "带教输入模式", control: inputModePicker, helpView: inputHelp)

        let concurrencyBox = makeTextInputBox(field: concurrency, placeholder: "1–10，默认 3")
        let concurrencyGroup = makeFieldGroup(title: "独立并发", control: concurrencyBox, help: "带教任务最大并行处理请求数（1–10，默认 3）")
        let timeoutBox = makeTextInputBox(field: timeout, placeholder: "5–600 秒，默认 30")
        let timeoutGroup = makeFieldGroup(title: "请求超时（秒）", control: timeoutBox, help: "单次带教请求截止等待时间（5–600 秒，默认 30）")
        let row3 = makeTwoColumnRow(left: concurrencyGroup, right: timeoutGroup)

        let stack = NSStackView(views: [header, row1, inputModeGroup, row3])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputModeGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row3.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return card
    }

    private func makePanelCard() -> CoachCardView {
        let card = CoachCardView()

        let header = makeCardHeader(
            icon: "macwindow.on.rectangle",
            title: "卡片浮窗呈现",
            subtitle: "设置带教建议浮窗在屏幕中的停靠位置与展示交互"
        )

        let cornerGroup = makeFieldGroup(title: "屏幕停靠角落", control: corner, help: "带教建议卡片在屏幕边缘浮动停靠的位置")

        let displayModeBox = makeDisplayModeBox()
        let displayGroup = makeFieldGroup(title: "呈现方式", control: displayModeBox, help: "录音结束后独立显示，支持一键收藏或移走")

        let row = makeTwoColumnRow(left: cornerGroup, right: displayGroup)

        let stack = NSStackView(views: [header, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return card
    }

    private func makePromptCard() -> CoachCardView {
        let card = CoachCardView()

        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = CoachTheme.pillBackground.cgColor
        badgeContainer.layer?.cornerRadius = 6
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(promptBadge)
        promptBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptBadge.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 8),
            promptBadge.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -8),
            promptBadge.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 4),
            promptBadge.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -4)
        ])

        let header = makeCardHeader(
            icon: "text.quote",
            title: "完整带教提示词",
            subtitle: "指导模型分析口述内容并给出针对性的发音、语法与用词改进建议",
            accessory: badgeContainer
        )

        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder
        promptScroll.wantsLayer = true
        promptScroll.layer?.cornerRadius = 10
        promptScroll.layer?.borderWidth = 1
        promptScroll.layer?.borderColor = CoachTheme.borderColor.cgColor
        promptScroll.translatesAutoresizingMaskIntoConstraints = false

        prompt.isRichText = false
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.font = .systemFont(ofSize: 13.5)
        prompt.textColor = CoachTheme.primaryText
        prompt.isHorizontallyResizable = false
        prompt.isVerticallyResizable = true
        prompt.autoresizingMask = [.width]
        prompt.textContainer?.widthTracksTextView = true
        prompt.textContainerInset = NSSize(width: 14, height: 14)
        prompt.delegate = self
        promptScroll.documentView = prompt

        let saveButton = CoachPrimaryButton(title: "保存带教配置", target: self, action: #selector(saveSettings))
        let restoreButton = CoachSecondaryButton(title: "恢复当前默认提示词", target: self, action: #selector(restorePrompt))
        let manageButton = CoachSecondaryButton(title: "共享服务设置…", target: self, action: #selector(openSharedServices))
        manageButton.isEnabled = onOpenSharedServices != nil

        let buttonsRow = NSStackView(views: [saveButton, restoreButton, manageButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 10
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        status.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, promptScroll, buttonsRow, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScroll.heightAnchor.constraint(equalToConstant: 210),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return card
    }

    // MARK: - Layout Helpers

    private func makeCardHeader(icon: String, title: String, subtitle: String, accessory: NSView? = nil) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: title)!)
        iconView.contentTintColor = CoachTheme.primaryBlue
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = CoachTheme.primaryText

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = CoachTheme.secondaryText

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let leadingStack = NSStackView(views: [iconView, textStack])
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .top
        leadingStack.spacing = 10
        leadingStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(leadingStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            leadingStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leadingStack.topAnchor.constraint(equalTo: container.topAnchor),
            leadingStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if let accessory {
            container.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                leadingStack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12)
            ])
        } else {
            leadingStack.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        }

        return container
    }

    private func makeFieldGroup(title: String, control: NSView, help: String? = nil, helpView: NSView? = nil) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = CoachTheme.primaryText
        container.addArrangedSubview(label)

        container.addArrangedSubview(control)
        control.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        if let helpView {
            container.addArrangedSubview(helpView)
            helpView.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        } else if let help {
            let helpLabel = NSTextField(wrappingLabelWithString: help)
            helpLabel.font = .systemFont(ofSize: 12)
            helpLabel.textColor = CoachTheme.secondaryText
            container.addArrangedSubview(helpLabel)
            helpLabel.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        return container
    }

    private func makeTwoColumnRow(left: NSView, right: NSView) -> NSStackView {
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeTextInputBox(field: NSTextField, placeholder: String) -> NSView {
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = CoachTheme.primaryText
        field.translatesAutoresizingMaskIntoConstraints = false

        let box = CoachInputBoxView()
        box.addSubview(field)

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 36),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    private func makeDisplayModeBox() -> NSView {
        let label = NSTextField(labelWithString: "非激活式浮窗（不抢占主输入焦点）")
        label.font = .systemFont(ofSize: 13)
        label.textColor = CoachTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = CoachInputBoxView()
        box.layer?.backgroundColor = CoachTheme.subtleGray.cgColor
        box.addSubview(label)

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 36),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }
}

// MARK: - Private Styling & Component Classes

private enum CoachTheme {
    static let canvasBackground = NSColor(srgbRed: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1.0)
    static let cardBackground = NSColor.white
    static let borderColor = NSColor(srgbRed: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0)
    static let primaryText = NSColor(srgbRed: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
    static let secondaryText = NSColor(srgbRed: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
    static let primaryBlue = NSColor(srgbRed: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 1.0)
    static let hoverBlue = NSColor(srgbRed: 0x24/255.0, green: 0x54/255.0, blue: 0xD1/255.0, alpha: 1.0)
    static let subtleGray = NSColor(srgbRed: 0xF4/255.0, green: 0xF6/255.0, blue: 0xF9/255.0, alpha: 1.0)
    static let pillBackground = NSColor(srgbRed: 0xEE/255.0, green: 0xF2/255.0, blue: 0xF6/255.0, alpha: 1.0)

    static func buttonAttributedTitle(_ title: String, color: NSColor, weight: NSFont.Weight) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }
}

private final class CoachCardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CoachTheme.cardBackground.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = CoachTheme.borderColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = CoachTheme.cardBackground.cgColor
        layer?.borderColor = CoachTheme.borderColor.cgColor
    }
}

private final class CoachInputBoxView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CoachTheme.cardBackground.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = CoachTheme.borderColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = CoachTheme.cardBackground.cgColor
        layer?.borderColor = CoachTheme.borderColor.cgColor
    }
}

private final class CoachPrimaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.backgroundColor = CoachTheme.primaryBlue.cgColor
        self.layer?.cornerRadius = 8
        self.attributedTitle = CoachTheme.buttonAttributedTitle(title, color: .white, weight: .semibold)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 38).isActive = true
        self.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = isHighlighted ? CoachTheme.hoverBlue.cgColor : CoachTheme.primaryBlue.cgColor
    }

    override var isHighlighted: Bool {
        didSet {
            layer?.backgroundColor = isHighlighted ? CoachTheme.hoverBlue.cgColor : CoachTheme.primaryBlue.cgColor
        }
    }
}

private final class CoachSecondaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.backgroundColor = CoachTheme.cardBackground.cgColor
        self.layer?.cornerRadius = 8
        self.layer?.borderWidth = 1
        self.layer?.borderColor = CoachTheme.borderColor.cgColor
        self.attributedTitle = CoachTheme.buttonAttributedTitle(title, color: CoachTheme.primaryText, weight: .medium)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 38).isActive = true
        self.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = isHighlighted ? CoachTheme.subtleGray.cgColor : CoachTheme.cardBackground.cgColor
        layer?.borderColor = CoachTheme.borderColor.cgColor
    }

    override var isHighlighted: Bool {
        didSet {
            layer?.backgroundColor = isHighlighted ? CoachTheme.subtleGray.cgColor : CoachTheme.cardBackground.cgColor
        }
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.45
        }
    }
}
