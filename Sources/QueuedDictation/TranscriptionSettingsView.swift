import AppKit

// MARK: - Visual Design Tokens

private enum Theme {
    static let background = NSColor(srgbRed: 248/255.0, green: 249/255.0, blue: 251/255.0, alpha: 1.0)
    static let cardBackground = NSColor.white
    static let textPrimary = NSColor(srgbRed: 36/255.0, green: 41/255.0, blue: 54/255.0, alpha: 1.0)
    static let textSecondary = NSColor(srgbRed: 133/255.0, green: 141/255.0, blue: 156/255.0, alpha: 1.0)
    static let border = NSColor(srgbRed: 229/255.0, green: 231/255.0, blue: 237/255.0, alpha: 1.0)
    static let primaryBlue = NSColor(srgbRed: 44/255.0, green: 98/255.0, blue: 239/255.0, alpha: 1.0)
    static let primaryBlueHover = NSColor(srgbRed: 27/255.0, green: 79/255.0, blue: 216/255.0, alpha: 1.0)
    static let secondaryHover = NSColor(srgbRed: 241/255.0, green: 243/255.0, blue: 247/255.0, alpha: 1.0)
    static let destructiveRed = NSColor(srgbRed: 229/255.0, green: 57/255.0, blue: 53/255.0, alpha: 1.0)
    static let badgeBlueBackground = NSColor(srgbRed: 238/255.0, green: 243/255.0, blue: 255/255.0, alpha: 1.0)
    static let badgeGrayBackground = NSColor(srgbRed: 243/255.0, green: 244/255.0, blue: 246/255.0, alpha: 1.0)

    static let cardRadius: CGFloat = 16.0
    static let controlRadius: CGFloat = 8.0
    static let controlHeight: CGFloat = 38.0
    static let cardPadding: CGFloat = 24.0
    static let moduleSpacing: CGFloat = 20.0
}

// MARK: - Custom Cells for Form Controls

private final class FormTextFieldCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 12.0

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        let yOffset = max(0, (rect.height - textSize.height) / 2.0)
        return NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y + yOffset,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: min(rect.height, textSize.height)
        )
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        let textSize = cellSize(forBounds: rect)
        let yOffset = max(0, (rect.height - textSize.height) / 2.0)
        let textFrame = NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y + yOffset,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: min(rect.height, textSize.height)
        )
        super.edit(withFrame: textFrame, in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        let textSize = cellSize(forBounds: rect)
        let yOffset = max(0, (rect.height - textSize.height) / 2.0)
        let textFrame = NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y + yOffset,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: min(rect.height, textSize.height)
        )
        super.select(withFrame: textFrame, in: controlView, editor: editor, delegate: delegate, start: selStart, length: selLength)
    }
}

private final class FormSecureTextFieldCell: NSSecureTextFieldCell {
    private let horizontalInset: CGFloat = 12.0

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        let yOffset = max(0, (rect.height - textSize.height) / 2.0)
        return NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y + yOffset,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: min(rect.height, textSize.height)
        )
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        let textSize = cellSize(forBounds: rect)
        let yOffset = max(0, (rect.height - textSize.height) / 2.0)
        let textFrame = NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y + yOffset,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: min(rect.height, textSize.height)
        )
        super.edit(withFrame: textFrame, in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        let textSize = cellSize(forBounds: rect)
        let yOffset = max(0, (rect.height - textSize.height) / 2.0)
        let textFrame = NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y + yOffset,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: min(rect.height, textSize.height)
        )
        super.select(withFrame: textFrame, in: controlView, editor: editor, delegate: delegate, start: selStart, length: selLength)
    }
}

// MARK: - Custom Buttons

private final class PrimaryActionButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    convenience init(title: String, target: Any?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target as AnyObject?
        self.action = action
        updateAttributedTitle()
    }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Theme.controlRadius
        layer?.backgroundColor = Theme.primaryBlue.cgColor
        focusRingType = .exterior
        updateAttributedTitle()
    }

    override var wantsUpdateLayer: Bool { true }

    override var title: String {
        didSet { updateAttributedTitle() }
    }

    private func updateAttributedTitle() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .paragraphStyle: style
            ]
        )
    }

    override func updateLayer() {
        super.updateLayer()
        if isHighlighted {
            layer?.backgroundColor = Theme.primaryBlueHover.cgColor
        } else {
            layer?.backgroundColor = Theme.primaryBlue.cgColor
        }
    }
}

private final class SecondaryActionButton: NSButton {
    var isDestructive: Bool = false {
        didSet { updateAttributedTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    convenience init(title: String, isDestructive: Bool = false, target: Any?, action: Selector?) {
        self.init(frame: .zero)
        self.isDestructive = isDestructive
        self.title = title
        self.target = target as AnyObject?
        self.action = action
        updateAttributedTitle()
    }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Theme.controlRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        layer?.backgroundColor = NSColor.white.cgColor
        focusRingType = .exterior
        updateAttributedTitle()
    }

    override var wantsUpdateLayer: Bool { true }

    override var title: String {
        didSet { updateAttributedTitle() }
    }

    private func updateAttributedTitle() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let color = isDestructive ? Theme.destructiveRed : Theme.textPrimary
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .paragraphStyle: style
            ]
        )
    }

    override func updateLayer() {
        super.updateLayer()
        if isHighlighted {
            layer?.backgroundColor = Theme.secondaryHover.cgColor
        } else {
            layer?.backgroundColor = NSColor.white.cgColor
        }
    }
}

// MARK: - Visual Containers & Helpers

private final class CardContainerView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.cardBackground.cgColor
        layer?.cornerRadius = Theme.cardRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
    }
}

private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, textColor: NSColor, backgroundColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = 5

        label.stringValue = text
        label.textColor = textColor
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class IconBadgeView: NSView {
    init(symbolName: String, tintColor: NSColor, backgroundColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = 8

        let imageView = NSImageView()
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            imageView.image = image
            imageView.contentTintColor = tintColor
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - TranscriptionSettingsView

@MainActor
final class TranscriptionSettingsView: NSView {
    override var isFlipped: Bool { true }

    // MARK: - Internal Controls (Exposed for AppDelegate Wiring)

    internal let servicePicker: NSPopUpButton
    internal let serviceName: NSTextField
    internal let baseURLField: NSTextField
    internal let modelField: NSTextField
    internal let keyField: NSSecureTextField
    internal let authPicker: NSPopUpButton
    internal let timeoutField: NSTextField
    internal let readiness: NSTextField
    internal let saveButton: NSButton
    internal let deleteKeyButton: NSButton
    internal let historyButton: NSButton

    // MARK: - Initializer

    override init(frame frameRect: NSRect) {
        // Initialize editable form controls with accessible styling
        modelField = Self.makeInputField(
            placeholder: "例如 whisper-1 或 SenseVoiceSmall",
            accessibilityLabel: "转写模型 ID"
        )
        timeoutField = Self.makeInputField(
            placeholder: "5–600 秒，默认 60",
            accessibilityLabel: "整体截止时间"
        )
        serviceName = Self.makeInputField(
            placeholder: "例如 个人 OpenAI / 本地端点",
            accessibilityLabel: "服务名称"
        )
        baseURLField = Self.makeInputField(
            placeholder: "https://api.openai.com/v1 或 http://localhost:8000/v1",
            accessibilityLabel: "Base URL"
        )
        keyField = Self.makeSecureInputField(
            placeholder: "新 API 密钥（空白保留；仅存钥匙串）",
            accessibilityLabel: "API 密钥"
        )

        // Initialize selectors
        servicePicker = Self.makePopUpButton(accessibilityLabel: "共享服务选择")
        let initialMenu = NSMenu()
        let newItem = NSMenuItem(title: "新增服务…", action: nil, keyEquivalent: "")
        newItem.representedObject = NSNull()
        initialMenu.addItem(newItem)
        servicePicker.menu = initialMenu

        authPicker = Self.makePopUpButton(accessibilityLabel: "服务鉴权方式")
        authPicker.removeAllItems()
        authPicker.addItems(withTitles: ["Bearer API 密钥", "无鉴权（自管本地端点）"])

        // Initialize status label
        let readinessLabel = NSTextField(wrappingLabelWithString: "")
        readinessLabel.isEditable = false
        readinessLabel.isSelectable = true
        readinessLabel.drawsBackground = false
        readinessLabel.isBezeled = false
        readinessLabel.lineBreakMode = .byWordWrapping
        readinessLabel.maximumNumberOfLines = 2
        readinessLabel.font = .systemFont(ofSize: 13)
        readinessLabel.textColor = Theme.textPrimary
        readinessLabel.placeholderString = "尚未配置转写服务和模型；有效录音会加密保存并等待配置。"
        readinessLabel.setAccessibilityLabel("转写配置就绪状态")
        readinessLabel.translatesAutoresizingMaskIntoConstraints = false
        readiness = readinessLabel

        // Initialize action buttons
        saveButton = PrimaryActionButton(title: "保存转写配置", target: nil, action: nil)
        saveButton.setAccessibilityLabel("保存转写配置")
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        deleteKeyButton = SecondaryActionButton(title: "删除所选服务密钥", isDestructive: true, target: nil, action: nil)
        deleteKeyButton.setAccessibilityLabel("删除所选服务密钥")
        deleteKeyButton.translatesAutoresizingMaskIntoConstraints = false

        historyButton = SecondaryActionButton(title: "查看语音历史", isDestructive: false, target: nil, action: nil)
        historyButton.setAccessibilityLabel("查看语音历史")
        historyButton.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)
        buildLayout()
        configureKeyViewLoop()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout Construction

    private func buildLayout() {
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        let modelCard = buildModelCard()
        let serviceCard = buildServiceCard()
        let statusCard = buildStatusCard()

        let mainStack = NSStackView(views: [modelCard, serviceCard, statusCard])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = Theme.moduleSpacing
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            modelCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            serviceCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            statusCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])
    }

    // MARK: - Card 1: 语音识别模型卡

    private func buildModelCard() -> NSView {
        let card = CardContainerView()
        card.translatesAutoresizingMaskIntoConstraints = false

        // Card Header
        let iconBadge = IconBadgeView(symbolName: "waveform", tintColor: Theme.primaryBlue, backgroundColor: Theme.badgeBlueBackground)
        let titleLabel = NSTextField(labelWithString: "语音识别")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        let tagBadge = BadgeView(text: "全局生效", textColor: Theme.textSecondary, backgroundColor: Theme.badgeGrayBackground)

        let titleRow = NSStackView(views: [iconBadge, titleLabel, tagBadge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10

        let subtitleLabel = NSTextField(wrappingLabelWithString: "配置录音文件的转写模型与超时控制。录音完成后音频直发所选服务端点。")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.textSecondary

        let headerStack = NSStackView(views: [titleRow, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        // Field Columns (2-column layout)
        let modelCol = Self.makeFieldBlock(
            label: "转写模型 ID",
            control: modelField,
            caption: "所选服务的文件转写模型标识 (例如 whisper-1)"
        )
        let timeoutCol = Self.makeFieldBlock(
            label: "整体截止时间 (秒)",
            control: timeoutField,
            caption: "单次转写请求允许的最大等待时长"
        )

        let fieldsRow = NSStackView(views: [modelCol, timeoutCol])
        fieldsRow.orientation = .horizontal
        fieldsRow.alignment = .top
        fieldsRow.distribution = .fillEqually
        fieldsRow.spacing = 16

        let contentStack = NSStackView(views: [headerStack, fieldsRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.cardPadding),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.cardPadding),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.cardPadding),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.cardPadding),
            fieldsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])

        return card
    }

    // MARK: - Card 2: 模型服务与 BYOK 卡

    private func buildServiceCard() -> NSView {
        let card = CardContainerView()
        card.translatesAutoresizingMaskIntoConstraints = false

        // Card Header
        let iconBadge = IconBadgeView(symbolName: "server.rack", tintColor: Theme.primaryBlue, backgroundColor: Theme.badgeBlueBackground)
        let titleLabel = NSTextField(labelWithString: "模型服务")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        let tagBadge = BadgeView(text: "自带密钥 (BYOK)", textColor: Theme.primaryBlue, backgroundColor: Theme.badgeBlueBackground)

        let titleRow = NSStackView(views: [iconBadge, titleLabel, tagBadge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10

        let subtitleLabel = NSTextField(wrappingLabelWithString: "多项功能可复用同一模型服务。服务密钥仅保存在本地 macOS Keychain 中，保护隐私安全。")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.textSecondary

        let headerStack = NSStackView(views: [titleRow, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        // Service Selector Block
        let servicePickerBlock = Self.makeFieldBlock(
            label: "已配置服务",
            control: servicePicker,
            caption: "选择已保存端点，或选择“新增服务…”创建新配置"
        )

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Service Details Block
        let serviceNameCol = Self.makeFieldBlock(
            label: "服务名称",
            control: serviceName,
            caption: "用于在应用内识别该端点"
        )
        let authCol = Self.makeFieldBlock(
            label: "服务鉴权",
            control: authPicker,
            caption: "公网 API 使用 Bearer 密钥，自建本地端点可选无鉴权"
        )

        let detailsTopRow = NSStackView(views: [serviceNameCol, authCol])
        detailsTopRow.orientation = .horizontal
        detailsTopRow.alignment = .top
        detailsTopRow.distribution = .fillEqually
        detailsTopRow.spacing = 16

        let baseURLBlock = Self.makeFieldBlock(
            label: "Base URL",
            control: baseURLField,
            caption: "指向兼容 /audio/transcriptions 规范的 HTTP(S) 地址"
        )

        let keyBlock = Self.makeFieldBlock(
            label: "API 密钥",
            control: keyField,
            caption: "密钥仅保存在本地 macOS 钥匙串中，界面不以明文显示"
        )

        // Action Buttons Row
        let buttonsRow = NSStackView(views: [saveButton, deleteKeyButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 12

        NSLayoutConstraint.activate([
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            deleteKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])

        let contentStack = NSStackView(views: [
            headerStack,
            servicePickerBlock,
            divider,
            detailsTopRow,
            baseURLBlock,
            keyBlock,
            buttonsRow
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.cardPadding),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.cardPadding),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.cardPadding),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.cardPadding),
            servicePickerBlock.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            detailsTopRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            baseURLBlock.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            keyBlock.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])

        return card
    }

    // MARK: - Card 3: 运行就绪与历史导航卡

    private func buildStatusCard() -> NSView {
        let card = CardContainerView()
        card.translatesAutoresizingMaskIntoConstraints = false

        // Status Feedback Container
        let statusBox = NSView()
        statusBox.wantsLayer = true
        statusBox.layer?.backgroundColor = Theme.background.cgColor
        statusBox.layer?.cornerRadius = 10
        statusBox.layer?.borderWidth = 1
        statusBox.layer?.borderColor = Theme.border.cgColor
        statusBox.translatesAutoresizingMaskIntoConstraints = false

        let statusIcon = NSImageView()
        if let image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "状态指示") {
            statusIcon.image = image
            statusIcon.contentTintColor = Theme.primaryBlue
        }
        statusIcon.translatesAutoresizingMaskIntoConstraints = false

        statusBox.addSubview(statusIcon)
        statusBox.addSubview(readiness)

        NSLayoutConstraint.activate([
            statusBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            statusIcon.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 14),
            statusIcon.centerYAnchor.constraint(equalTo: statusBox.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
            readiness.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 10),
            readiness.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -14),
            readiness.centerYAnchor.constraint(equalTo: statusBox.centerYAnchor)
        ])

        // Bottom Footer: Privacy Notice & History Button
        let privacyLabel = NSTextField(wrappingLabelWithString: "仅在录音完成时直发音频与模型 ID 到配置端点。本地 HTTP 连接遵循系统局域网权限。")
        privacyLabel.font = .systemFont(ofSize: 12)
        privacyLabel.textColor = Theme.textSecondary
        privacyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footerRow = NSStackView(views: [privacyLabel, historyButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 16

        NSLayoutConstraint.activate([
            historyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        let contentStack = NSStackView(views: [statusBox, footerRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            statusBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])

        return card
    }

    // MARK: - Key View Loop for Keyboard Accessibility

    private func configureKeyViewLoop() {
        modelField.nextKeyView = timeoutField
        timeoutField.nextKeyView = servicePicker
        servicePicker.nextKeyView = serviceName
        serviceName.nextKeyView = authPicker
        authPicker.nextKeyView = baseURLField
        baseURLField.nextKeyView = keyField
        keyField.nextKeyView = saveButton
        saveButton.nextKeyView = deleteKeyButton
        deleteKeyButton.nextKeyView = historyButton
    }

    // MARK: - Control Factory Helpers

    private static func makeInputField(placeholder: String, accessibilityLabel: String) -> NSTextField {
        let field = NSTextField()
        let customCell = FormTextFieldCell(textCell: "")
        customCell.isScrollable = true
        customCell.wraps = false
        field.cell = customCell
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.wantsLayer = true
        field.layer?.cornerRadius = Theme.controlRadius
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Theme.border.cgColor
        field.layer?.backgroundColor = NSColor.white.cgColor
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.textColor = Theme.textPrimary
        field.focusRingType = .exterior
        field.setAccessibilityLabel(accessibilityLabel)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: Theme.controlHeight).isActive = true
        return field
    }

    private static func makeSecureInputField(placeholder: String, accessibilityLabel: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        let customCell = FormSecureTextFieldCell(textCell: "")
        customCell.isScrollable = true
        customCell.wraps = false
        field.cell = customCell
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.wantsLayer = true
        field.layer?.cornerRadius = Theme.controlRadius
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Theme.border.cgColor
        field.layer?.backgroundColor = NSColor.white.cgColor
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.textColor = Theme.textPrimary
        field.focusRingType = .exterior
        field.setAccessibilityLabel(accessibilityLabel)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: Theme.controlHeight).isActive = true
        return field
    }

    private static func makePopUpButton(accessibilityLabel: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 13)
        popup.setAccessibilityLabel(accessibilityLabel)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.heightAnchor.constraint(equalToConstant: Theme.controlHeight).isActive = true
        return popup
    }

    private static func makeFieldBlock(label: String, control: NSView, caption: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.textPrimary

        let captionLabel = NSTextField(wrappingLabelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = Theme.textSecondary

        let stack = NSStackView(views: [titleLabel, control, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        captionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
}
