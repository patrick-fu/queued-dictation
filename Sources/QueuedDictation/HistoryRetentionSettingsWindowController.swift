import AppKit
import DictationCore

@MainActor
final class HistoryRetentionSettingsWindowController: NSWindowController {
    private let settings: HistoryRetentionSettings
    private let configurationChanged: @MainActor () -> Void
    private let period = NSPopUpButton(frame: .zero, pullsDown: false)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var chipButtons: [RetentionChipButton] = []
    private var didPrepareEmbeddedView = false

    private var saveButton: RetentionPrimaryButton!
    private var reloadButton: RetentionSecondaryButton!

    init(settings: HistoryRetentionSettings, configurationChanged: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.configurationChanged = configurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "语音历史保留设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 460)
        window.center()

        let menu = NSMenu()
        for value in HistoryRetentionPeriod.allCases {
            let item = NSMenuItem(title: value == .days30 ? "\(value.title)（默认）" : value.title, action: nil, keyEquivalent: "")
            item.representedObject = value.rawValue
            menu.addItem(item)
        }
        period.menu = menu
        period.target = self
        period.action = #selector(periodPopupChanged)
        period.font = .systemFont(ofSize: 13)

        message.textColor = RetentionPalette.errorRed
        message.font = .systemFont(ofSize: 12)
        message.lineBreakMode = .byWordWrapping

        setupLayout(in: window)
        select(.days30)
    }

    required init?(coder: NSCoder) { nil }

    func prepareEmbeddedView() {
        guard !didPrepareEmbeddedView else { return }
        didPrepareEmbeddedView = true
        do {
            select(try settings.load())
            message.stringValue = ""
        } catch {
            message.stringValue = failureMessage(error)
            message.textColor = RetentionPalette.errorRed
        }
    }

    func showSettings() {
        prepareEmbeddedView()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ value: HistoryRetentionPeriod) {
        period.select(period.itemArray.first { $0.representedObject as? Int == value.rawValue })
        updateChipSelection(value)
    }

    private func updateChipSelection(_ selectedPeriod: HistoryRetentionPeriod) {
        for chip in chipButtons {
            chip.isSelected = (chip.period == selectedPeriod)
        }
    }

    @objc private func periodPopupChanged() {
        if let value = period.selectedItem?.representedObject as? Int,
           let selected = HistoryRetentionPeriod(rawValue: value) {
            updateChipSelection(selected)
        }
    }

    @objc private func chipClicked(_ sender: RetentionChipButton) {
        select(sender.period)
    }

    @objc private func reloadSettings() {
        do {
            let loaded = try settings.load()
            select(loaded)
            message.stringValue = ""
        } catch {
            message.stringValue = failureMessage(error)
            message.textColor = RetentionPalette.errorRed
        }
    }

    @objc private func saveSettings() {
        do {
            guard let value = period.selectedItem?.representedObject as? Int,
                  let selected = HistoryRetentionPeriod(rawValue: value) else { throw HistoryRetentionSettingsError.invalidPeriod }
            try settings.save(selected)
            message.stringValue = "历史保留设置已成功保存。"
            message.textColor = RetentionPalette.textSecondary
            configurationChanged()
        } catch {
            message.stringValue = failureMessage(error)
            message.textColor = RetentionPalette.errorRed
        }
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? HistoryRetentionSettingsError)?.localizedDescription ?? "历史保留设置未能保存，请检查配置目录与可用空间。"
    }

    private func setupLayout(in window: NSWindow) {
        let root = RetentionContentView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let titleLabel = NSTextField(labelWithString: "语音历史保留设置")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = RetentionPalette.textPrimary
        headerStack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "设置已完成转写的常规录音保留时长，超期将自动清理。带教收藏独立保存。")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = RetentionPalette.textSecondary
        headerStack.addArrangedSubview(subtitleLabel)

        let chipsStack = NSStackView()
        chipsStack.orientation = .horizontal
        chipsStack.spacing = 8
        chipsStack.alignment = .centerY

        for value in HistoryRetentionPeriod.allCases {
            let title = (value == .days30) ? "30 天（默认）" : value.title
            let chip = RetentionChipButton(title: title, period: value, target: self, action: #selector(chipClicked(_:)))
            chipButtons.append(chip)
            chipsStack.addArrangedSubview(chip)
        }

        let popupRow = NSStackView()
        popupRow.orientation = .horizontal
        popupRow.spacing = 10
        popupRow.alignment = .centerY

        let popupLabel = NSTextField(labelWithString: "下拉选择")
        popupLabel.font = .systemFont(ofSize: 13, weight: .medium)
        popupLabel.textColor = RetentionPalette.textPrimary
        popupRow.addArrangedSubview(popupLabel)
        popupRow.addArrangedSubview(period)
        period.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let retentionNotice = NSTextField(wrappingLabelWithString:
            "默认 30 天。系统在超过保留期后自动清理旧片段。未终结的片段和仍在处理的工作会保留。永久仍受本地空间额度限制。")
        retentionNotice.font = .systemFont(ofSize: 12)
        retentionNotice.textColor = RetentionPalette.textSecondary

        let retentionCard = RetentionCardView(
            title: "普通语音历史保留期",
            subtitle: "决定已完成交付的录音、音频文件和文本在本地保留的时间。",
            contentViews: [chipsStack, popupRow, retentionNotice]
        )

        let favoritesDesc = NSTextField(wrappingLabelWithString:
            "带教收藏独立保存于专属存储，不随历史清理而被删除。即使普通历史到达保留期被自动清理或手动清空，你的带教建议与参考表达仍完整保留。")
        favoritesDesc.font = .systemFont(ofSize: 12)
        favoritesDesc.textColor = RetentionPalette.textSecondary

        let favoritesCard = RetentionCardView(
            title: "带教收藏独立说明",
            subtitle: "带教建议卡片采用独立管理机制。",
            contentViews: [favoritesDesc]
        )

        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.distribution = .fill
        footerStack.spacing = 14

        reloadButton = RetentionSecondaryButton(title: "重新读取", target: self, action: #selector(reloadSettings))
        saveButton = RetentionPrimaryButton(title: "保存保留期", target: self, action: #selector(saveSettings))

        let buttonsStack = NSStackView(views: [reloadButton, saveButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 12

        footerStack.addArrangedSubview(message)
        footerStack.addArrangedSubview(buttonsStack)
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonsStack.setContentHuggingPriority(.required, for: .horizontal)

        let mainStack = NSStackView(views: [headerStack, retentionCard, favoritesCard, footerStack])
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
            retentionCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            favoritesCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])
    }
}

// MARK: - Private Styling and Helper Components

private enum RetentionPalette {
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

private final class RetentionContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class RetentionCardView: NSView {
    init(title: String, subtitle: String? = nil, contentViews: [NSView] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = RetentionPalette.cardBackground.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = RetentionPalette.border.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let innerStack = NSStackView()
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 14
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(innerStack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = RetentionPalette.textPrimary
        innerStack.addArrangedSubview(titleLabel)

        if let subtitle = subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = RetentionPalette.textSecondary
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

private final class RetentionChipButton: NSButton {
    let period: HistoryRetentionPeriod
    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }
    private let chipTitle: String

    init(title: String, period: HistoryRetentionPeriod, target: AnyObject?, action: Selector?) {
        self.period = period
        self.chipTitle = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        let minWidth = max(CGFloat(title.count * 14 + 24), 68.0)
        widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func updateAppearance() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        if isSelected {
            layer?.borderWidth = 1.5
            layer?.borderColor = RetentionPalette.primaryBlue.cgColor
            layer?.backgroundColor = RetentionPalette.primaryBlueSubtle.cgColor
            attributedTitle = NSAttributedString(
                string: chipTitle,
                attributes: [
                    .foregroundColor: RetentionPalette.primaryBlue,
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .paragraphStyle: paragraph
                ]
            )
        } else {
            layer?.borderWidth = 1.0
            layer?.borderColor = RetentionPalette.border.cgColor
            layer?.backgroundColor = RetentionPalette.cardBackground.cgColor
            attributedTitle = NSAttributedString(
                string: chipTitle,
                attributes: [
                    .foregroundColor: RetentionPalette.textPrimary,
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .paragraphStyle: paragraph
                ]
            )
        }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        if !isSelected {
            layer?.backgroundColor = flag ? NSColor(srgbRed: 0xF3/255.0, green: 0xF4/255.0, blue: 0xF6/255.0, alpha: 1.0).cgColor : RetentionPalette.cardBackground.cgColor
        }
    }
}

private final class RetentionPrimaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        layer?.backgroundColor = RetentionPalette.primaryBlue.cgColor

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
        layer?.backgroundColor = flag ? RetentionPalette.primaryBlueHover.cgColor : RetentionPalette.primaryBlue.cgColor
    }
}

private final class RetentionSecondaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = RetentionPalette.border.cgColor
        layer?.backgroundColor = RetentionPalette.cardBackground.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: RetentionPalette.textPrimary,
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
            : RetentionPalette.cardBackground.cgColor
    }
}
