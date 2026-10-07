import AppKit
import DictationCore

@MainActor
final class DeliverySettingsWindowController: NSWindowController {
    private let settings: DeliverySettings
    private let delivery: CrossAppTextDelivery
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var optionCard0: DeliveryOptionCardView!
    private var optionCard1: DeliveryOptionCardView!
    private var saveButton: DeliveryPrimaryButton!
    private var reloadButton: DeliverySecondaryButton!

    init(settings: DeliverySettings, delivery: CrossAppTextDelivery) {
        self.settings = settings
        self.delivery = delivery
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "文本上屏"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 480)
        window.center()

        mode.addItems(withTitles: ["录音时输入框（默认）", "交付时当前光标"])
        mode.target = self
        mode.action = #selector(saveSelectedMode)
        mode.font = .systemFont(ofSize: 13)

        errorLabel.textColor = DeliveryPalette.errorRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.lineBreakMode = .byWordWrapping

        statusLabel.textColor = DeliveryPalette.textSecondary
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byWordWrapping

        descriptionLabel.textColor = DeliveryPalette.textSecondary
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.lineBreakMode = .byWordWrapping

        setupLayout(in: window)
        loadConfiguration()
        render()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        loadConfiguration()
        render()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func prepareEmbeddedView() {
        loadConfiguration()
        render()
    }

    func render() {
        let isRecordingTarget = delivery.configuration.mode == .recordingTarget
        mode.selectItem(at: isRecordingTarget ? 0 : 1)
        optionCard0.isSelected = isRecordingTarget
        optionCard1.isSelected = !isRecordingTarget

        descriptionLabel.stringValue = isRecordingTarget
            ? "开始录音时记录输入框与光标。交付前如果曾失焦、关闭、手打、移动光标或无法确认未变，保留结果待手动上屏。"
            : "只在本段真正轮到交付时，向当时聚焦的可写输入框插入。此模式不保护开始录音时的位置；没有可靠可写目标仍待手动上屏。"

        statusLabel.stringValue = delivery.automaticDeliveryEnabled
            ? (delivery.accessibilityAuthorized ? "辅助功能已获准；能否自动上屏取决于目标控件的实际核验。" : "辅助功能未获准；结果可在队列中手动取用。")
            : "上屏设置未就绪，自动上屏暂停；重新选择并保存后生效。"
    }

    private func loadConfiguration() {
        do {
            delivery.updateConfiguration(try settings.load())
            delivery.automaticDeliveryEnabled = true
            errorLabel.stringValue = ""
        } catch {
            delivery.automaticDeliveryEnabled = false
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func saveSelectedMode() {
        let configuration = DeliveryConfiguration(mode: mode.indexOfSelectedItem == 0 ? .recordingTarget : .currentCursor)
        do {
            try settings.save(configuration)
            delivery.updateConfiguration(configuration)
            delivery.automaticDeliveryEnabled = true
            errorLabel.stringValue = ""
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
        render()
    }

    @objc private func reloadConfiguration() {
        loadConfiguration()
        render()
    }

    @objc private func selectMode0() {
        mode.selectItem(at: 0)
        saveSelectedMode()
    }

    @objc private func selectMode1() {
        mode.selectItem(at: 1)
        saveSelectedMode()
    }

    private func setupLayout(in window: NSWindow) {
        let root = DeliveryContentView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let titleLabel = NSTextField(labelWithString: "选择每段语音的上屏位置")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = DeliveryPalette.textPrimary
        headerStack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "设置录音转写完成后的文本自动写回位置与核验保护策略。")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = DeliveryPalette.textSecondary
        headerStack.addArrangedSubview(subtitleLabel)

        optionCard0 = DeliveryOptionCardView(
            title: "录音时输入框",
            badge: "推荐 / 默认",
            explanation: "开始录音时记录输入框与光标。交付前如果曾失焦、关闭、手打、移动光标或无法确认未变，保留结果待手动上屏。",
            target: self,
            action: #selector(selectMode0)
        )

        optionCard1 = DeliveryOptionCardView(
            title: "交付时当前光标",
            badge: "即时跟随",
            explanation: "只在本段真正轮到交付时，向当时聚焦的可写输入框插入。此模式不保护开始录音时的位置；没有可靠可写目标仍待手动上屏。",
            target: self,
            action: #selector(selectMode1)
        )

        let optionsStack = NSStackView(views: [optionCard0, optionCard1])
        optionsStack.orientation = .horizontal
        optionsStack.distribution = .fillEqually
        optionsStack.spacing = 14
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        let popupRow = NSStackView()
        popupRow.orientation = .horizontal
        popupRow.spacing = 10
        popupRow.alignment = .centerY

        let popupLabel = NSTextField(labelWithString: "当前选择")
        popupLabel.font = .systemFont(ofSize: 13, weight: .medium)
        popupLabel.textColor = DeliveryPalette.textPrimary
        popupRow.addArrangedSubview(popupLabel)
        popupRow.addArrangedSubview(mode)
        mode.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let card = DeliveryCardView(
            title: "上屏目标模式",
            subtitle: "决定录音结束后自动填入的目标输入框。未修改或无法核验时将保留待手动交付。",
            contentViews: [optionsStack, popupRow]
        )

        let help = NSTextField(wrappingLabelWithString:
            "保存后只影响新开始的片段。已有片段仍沿用开始录音时的模式。密码、安全输入或无法可靠核验的控件均待手动上屏；复制不会放行队列，写回不确定时请检查目标并确认。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = DeliveryPalette.textSecondary

        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.distribution = .fill
        footerStack.spacing = 14

        let statusBox = NSStackView(views: [statusLabel, errorLabel])
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.spacing = 4

        reloadButton = DeliverySecondaryButton(title: "重新读取", target: self, action: #selector(reloadConfiguration))
        saveButton = DeliveryPrimaryButton(title: "保存设置", target: self, action: #selector(saveSelectedMode))

        let buttonsStack = NSStackView(views: [reloadButton, saveButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 12

        footerStack.addArrangedSubview(statusBox)
        footerStack.addArrangedSubview(buttonsStack)
        statusBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonsStack.setContentHuggingPriority(.required, for: .horizontal)

        let mainStack = NSStackView(views: [headerStack, card, help, footerStack])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            headerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            card.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            help.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])
    }
}

// MARK: - Private Styling and Helper Components

private enum DeliveryPalette {
    static let canvasBackground = NSColor(srgbRed: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1.0)
    static let cardBackground = NSColor.white
    static let border = NSColor(srgbRed: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0)
    static let textPrimary = NSColor(srgbRed: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
    static let textSecondary = NSColor(srgbRed: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
    static let primaryBlue = NSColor(srgbRed: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 1.0)
    static let primaryBlueHover = NSColor(srgbRed: 0x1E/255.0, green: 0x50/255.0, blue: 0xD8/255.0, alpha: 1.0)
    static let primaryBlueSubtle = NSColor(srgbRed: 0xF0/255.0, green: 0xF4/255.0, blue: 0xFF/255.0, alpha: 1.0)
    static let errorRed = NSColor(srgbRed: 0xEF/255.0, green: 0x44/255.0, blue: 0x44/255.0, alpha: 1.0)
}

private final class DeliveryContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class DeliveryCardView: NSView {
    init(title: String, subtitle: String? = nil, contentViews: [NSView] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DeliveryPalette.cardBackground.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = DeliveryPalette.border.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let innerStack = NSStackView()
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 16
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(innerStack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = DeliveryPalette.textPrimary
        innerStack.addArrangedSubview(titleLabel)

        if let subtitle = subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = DeliveryPalette.textSecondary
            innerStack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
            innerStack.setCustomSpacing(14, after: subtitleLabel)
        } else {
            innerStack.setCustomSpacing(14, after: titleLabel)
        }

        for view in contentViews {
            innerStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            innerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            innerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            innerStack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            innerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class DeliveryOptionCardView: NSView {
    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let indicatorDot = NSView()
    private weak var target: AnyObject?
    private let action: Selector?

    init(title: String, badge: String, explanation: String, target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false

        indicatorDot.wantsLayer = true
        indicatorDot.layer?.cornerRadius = 6
        indicatorDot.layer?.borderWidth = 1.5
        indicatorDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicatorDot.widthAnchor.constraint(equalToConstant: 12),
            indicatorDot.heightAnchor.constraint(equalToConstant: 12)
        ])

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = DeliveryPalette.textPrimary

        badgeLabel.stringValue = badge
        badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        badgeLabel.textColor = DeliveryPalette.primaryBlue

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 6
        badgeContainer.layer?.backgroundColor = DeliveryPalette.primaryBlueSubtle.cgColor
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -2)
        ])

        let topRow = NSStackView(views: [indicatorDot, titleLabel, badgeContainer])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY

        explanationLabel.stringValue = explanation
        explanationLabel.font = .systemFont(ofSize: 12)
        explanationLabel.textColor = DeliveryPalette.textSecondary
        explanationLabel.lineBreakMode = .byWordWrapping

        let cardStack = NSStackView(views: [topRow, explanationLabel])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardStack)

        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            topRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            explanationLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor)
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func updateAppearance() {
        if isSelected {
            layer?.borderColor = DeliveryPalette.primaryBlue.cgColor
            layer?.borderWidth = 1.5
            layer?.backgroundColor = DeliveryPalette.primaryBlueSubtle.cgColor
            indicatorDot.layer?.borderColor = DeliveryPalette.primaryBlue.cgColor
            indicatorDot.layer?.backgroundColor = DeliveryPalette.primaryBlue.cgColor
        } else {
            layer?.borderColor = DeliveryPalette.border.cgColor
            layer?.borderWidth = 1.0
            layer?.backgroundColor = DeliveryPalette.cardBackground.cgColor
            indicatorDot.layer?.borderColor = DeliveryPalette.border.cgColor
            indicatorDot.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let target = target, let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

private final class DeliveryPrimaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        layer?.backgroundColor = DeliveryPalette.primaryBlue.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .paragraphStyle: paragraph
            ]
        )
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag ? DeliveryPalette.primaryBlueHover.cgColor : DeliveryPalette.primaryBlue.cgColor
    }
}

private final class DeliverySecondaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = DeliveryPalette.border.cgColor
        layer?.backgroundColor = DeliveryPalette.cardBackground.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: DeliveryPalette.textPrimary,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .paragraphStyle: paragraph
            ]
        )
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag
            ? NSColor(srgbRed: 0xF3/255.0, green: 0xF4/255.0, blue: 0xF6/255.0, alpha: 1.0).cgColor
            : DeliveryPalette.cardBackground.cgColor
    }
}
