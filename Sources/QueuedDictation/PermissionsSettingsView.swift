import AppKit

@MainActor
final class PermissionsSettingsView: NSView {
    // MARK: - Exposed Properties Required by AppDelegate
    let microphoneStatus: NSTextField
    let accessibilityStatus: NSTextField
    let hotkeyStatus: NSTextField
    let microphoneButton: NSButton
    let accessibilityButton: NSButton
    let hotkeyButton: NSButton

    // MARK: - Layout Configuration
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        // Instantiate real AppKit status labels
        let micStatus = PermissionStatusField()
        let axStatus = PermissionStatusField()
        let hkStatus = PermissionStatusField()

        micStatus.stringValue = "麦克风：检查中…"
        axStatus.stringValue = "辅助功能：检查中…"
        hkStatus.stringValue = "快捷键监听：检查中…"

        self.microphoneStatus = micStatus
        self.accessibilityStatus = axStatus
        self.hotkeyStatus = hkStatus

        // Instantiate real AppKit action buttons (height 36, keyboard accessible)
        let micBtn = PermissionActionButton(title: "麦克风权限…")
        let axBtn = PermissionActionButton(title: "辅助功能权限…")
        let hkBtn = PermissionActionButton(title: "输入监控设置…")

        self.microphoneButton = micBtn
        self.accessibilityButton = axBtn
        self.hotkeyButton = hkBtn

        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        let micStatus = PermissionStatusField()
        let axStatus = PermissionStatusField()
        let hkStatus = PermissionStatusField()

        micStatus.stringValue = "麦克风：检查中…"
        axStatus.stringValue = "辅助功能：检查中…"
        hkStatus.stringValue = "快捷键监听：检查中…"

        self.microphoneStatus = micStatus
        self.accessibilityStatus = axStatus
        self.hotkeyStatus = hkStatus

        let micBtn = PermissionActionButton(title: "麦克风权限…")
        let axBtn = PermissionActionButton(title: "辅助功能权限…")
        let hkBtn = PermissionActionButton(title: "输入监控设置…")

        self.microphoneButton = micBtn
        self.accessibilityButton = axBtn
        self.hotkeyButton = hkBtn

        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        // Header Section
        let titleLabel = NSTextField(labelWithString: "系统权限与辅助功能")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        let subtitleLabel = NSTextField(wrappingLabelWithString: "为了确保语音能够正常录音并将转写文本直接填入其他应用，需要授予以下系统权限。")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Three Cards
        let micCard = PermissionCardView(
            iconName: "mic.fill",
            iconDescription: "麦克风",
            title: "麦克风",
            description: "用于语音输入实时录音。音频仅在本地采集，并发送至你配置的转写服务。",
            statusField: microphoneStatus as! PermissionStatusField,
            button: microphoneButton
        )

        let axCard = PermissionCardView(
            iconName: "hand.point.up.left.fill",
            iconDescription: "辅助功能",
            title: "辅助功能",
            description: "用于识别当前活动应用程序及光标所在输入框，并将转写或润色结果自动键入目标。",
            statusField: accessibilityStatus as! PermissionStatusField,
            button: accessibilityButton
        )

        let hkCard = PermissionCardView(
            iconName: "keyboard.fill",
            iconDescription: "快捷键监听",
            title: "快捷键监听",
            description: "用于全局监听录音快捷键（如 Fn / Globe），在任意前台界面快速开始或结束录音。",
            statusField: hotkeyStatus as! PermissionStatusField,
            button: hotkeyButton
        )

        // Main Vertical Stack (Module Spacing: 20pt)
        let mainStack = NSStackView(views: [headerStack, micCard, axCard, hkCard])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        for view in [headerStack, micCard, axCard, hkCard] {
            view.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }
        let bottomConstraint = mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)
        bottomConstraint.priority = .init(999)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            bottomConstraint
        ])
    }
}

// MARK: - Design Theme
private enum Theme {
    static let textPrimary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
            : NSColor(srgbRed: 0x24 / 255.0, green: 0x29 / 255.0, blue: 0x36 / 255.0, alpha: 1.0)
    }

    static let textSecondary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.65, blue: 0.70, alpha: 1.0)
            : NSColor(srgbRed: 0x85 / 255.0, green: 0x8D / 255.0, blue: 0x9C / 255.0, alpha: 1.0)
    }

    static let borderLight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.25, green: 0.27, blue: 0.31, alpha: 1.0)
            : NSColor(srgbRed: 0xE5 / 255.0, green: 0xE7 / 255.0, blue: 0xED / 255.0, alpha: 1.0)
    }

    static let cardBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    }

    static let primaryBlue = NSColor(srgbRed: 0x2C / 255.0, green: 0x62 / 255.0, blue: 0xEF / 255.0, alpha: 1.0)

    static let iconBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.20, green: 0.22, blue: 0.26, alpha: 1.0)
            : NSColor(srgbRed: 0xF8 / 255.0, green: 0xF9 / 255.0, blue: 0xFB / 255.0, alpha: 1.0)
    }

    static let statusBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.19, green: 0.21, blue: 0.24, alpha: 1.0)
            : NSColor(srgbRed: 0xF8 / 255.0, green: 0xF9 / 255.0, blue: 0xFB / 255.0, alpha: 1.0)
    }

    static let statusSuccess = NSColor(srgbRed: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0, alpha: 1.0)
    static let statusWarning = NSColor(srgbRed: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0, alpha: 1.0)
    static let statusNeutral = NSColor(srgbRed: 0x85 / 255.0, green: 0x8D / 255.0, blue: 0x9C / 255.0, alpha: 1.0)
}

// MARK: - Action Button (Height 36, AppKit accessible)
@MainActor
final class PermissionActionButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Theme.borderLight.cgColor
        layer?.backgroundColor = Theme.cardBackground.cgColor
        contentTintColor = Theme.primaryBlue
        font = .systemFont(ofSize: 13, weight: .medium)
        alignment = .center
        focusRingType = .default

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])
    }

    override var isHighlighted: Bool {
        didSet {
            layer?.backgroundColor = isHighlighted
                ? Theme.statusBackground.cgColor
                : Theme.cardBackground.cgColor
        }
    }
}

// MARK: - Status Field with Live Status Indicator Observer
@MainActor
final class PermissionStatusField: NSTextField {
    var onStatusChange: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isSelectable = true
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 3
        font = .systemFont(ofSize: 13, weight: .regular)
        textColor = Theme.textPrimary
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var stringValue: String {
        didSet {
            onStatusChange?(stringValue)
        }
    }
}

// MARK: - Card View (16 Radius White Card, 22-24 Padding, Light Border)
@MainActor
private final class PermissionCardView: NSView {
    private let statusDot = NSView()

    init(
        iconName: String,
        iconDescription: String,
        title: String,
        description: String,
        statusField: PermissionStatusField,
        button: NSButton
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.cardBackground.cgColor
        layer?.borderColor = Theme.borderLight.cgColor
        layer?.borderWidth = 1.0
        layer?.cornerRadius = 16.0

        // 1. Icon View (40x40 rounded rect with light gray #F8F9FB)
        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = Theme.iconBackground.cgColor
        iconBox.layer?.borderColor = Theme.borderLight.cgColor
        iconBox.layer?.borderWidth = 0.5
        iconBox.layer?.cornerRadius = 10
        iconBox.translatesAutoresizingMaskIntoConstraints = false

        let symbolImage = NSImage(systemSymbolName: iconName, accessibilityDescription: iconDescription)
            ?? NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: iconDescription)!
        let imageView = NSImageView(image: symbolImage)
        imageView.contentTintColor = Theme.primaryBlue
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(imageView)

        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 40),
            iconBox.heightAnchor.constraint(equalToConstant: 40),
            imageView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20)
        ])

        // 2. Titles Stack
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = Theme.textSecondary
        descLabel.maximumNumberOfLines = 2
        descLabel.lineBreakMode = .byWordWrapping

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        // 3. Top Row Stack (Icon + Text + Action Button)
        let topRow = NSStackView(views: [iconBox, textStack, button])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14
        topRow.translatesAutoresizingMaskIntoConstraints = false

        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconBox.setContentHuggingPriority(.required, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 4. Status Indicator Box (#F8F9FB background, 8 radius)
        let statusBox = NSView()
        statusBox.wantsLayer = true
        statusBox.layer?.backgroundColor = Theme.statusBackground.cgColor
        statusBox.layer?.borderColor = Theme.borderLight.cgColor
        statusBox.layer?.borderWidth = 0.5
        statusBox.layer?.cornerRadius = 8
        statusBox.translatesAutoresizingMaskIntoConstraints = false

        // Status Indicator Dot (7x7)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = Theme.statusNeutral.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        let statusContent = NSStackView(views: [statusDot, statusField])
        statusContent.orientation = .horizontal
        statusContent.alignment = .centerY
        statusContent.spacing = 8
        statusContent.translatesAutoresizingMaskIntoConstraints = false
        statusBox.addSubview(statusContent)

        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusContent.topAnchor.constraint(equalTo: statusBox.topAnchor, constant: 8),
            statusContent.bottomAnchor.constraint(equalTo: statusBox.bottomAnchor, constant: -8),
            statusContent.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 12),
            statusContent.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -12)
        ])

        updateDotColor(for: statusField.stringValue)
        statusField.onStatusChange = { [weak self] string in
            self?.updateDotColor(for: string)
        }

        // 5. Card Container Layout (Padding: 22pt vertical, 24pt horizontal)
        addSubview(topRow)
        addSubview(statusBox)

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            statusBox.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 14),
            statusBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            statusBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            statusBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func updateDotColor(for status: String) {
        let color: NSColor
        if status.contains("已允许") || status.contains("已就绪") || status.contains("已注册") {
            color = Theme.statusSuccess
        } else if status.contains("未允许") || status.contains("尚未") || status.contains("未获准") || status.contains("检查中") {
            color = Theme.statusWarning
        } else if status.contains("拒绝") || status.contains("限制") || status.contains("不可用") || status.contains("暂停") {
            color = Theme.statusNeutral
        } else {
            color = Theme.statusNeutral
        }
        statusDot.layer?.backgroundColor = color.cgColor
    }
}
