import AppKit

@MainActor
final class HistoryPageView: NSView, NSMenuItemValidation {
    internal let table: NSTableView
    internal let recoverySummary: NSTextField
    internal let message: NSTextField
    internal let recoveryContainer: NSStackView
    internal let buttons: [String: NSButton]

    private let scrollView = NSScrollView()
    private let emptyStateView = NSStackView()
    private let hiddenProxyContainer = NSView()
    private let downloadPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let morePopUp = NSPopUpButton(frame: .zero, pullsDown: true)

    override init(frame frameRect: NSRect) {
        let historyTable = HistoryTableView()
        self.table = historyTable
        self.recoverySummary = NSTextField(wrappingLabelWithString: "")
        self.message = NSTextField(wrappingLabelWithString: "")
        self.recoveryContainer = NSStackView()

        let copyBtn = HistoryActionButton(title: "复制文本", style: .primary)
        let detailsBtn = HistoryActionButton(title: "查看详情…", style: .secondary)
        let manualBtn = HistoryActionButton(title: "手动交付…", style: .secondary)
        let allBtn = HistoryFilterButton(title: "全部语音历史")
        let recoveryBtn = HistoryFilterButton(title: "重启恢复清单")

        let audioBtn = NSButton(title: "下载音频…", target: nil, action: nil)
        let cancelBtn = NSButton(title: "取消片段", target: nil, action: nil)
        let deleteBtn = NSButton(title: "删除历史…", target: nil, action: nil)
        let rawBtn = NSButton(title: "下载转写…", target: nil, action: nil)
        let retryBtn = NSButton(title: "显式重试转写", target: nil, action: nil)
        let repolishBtn = NSButton(title: "仅重新润色", target: nil, action: nil)
        let polishedBtn = NSButton(title: "下载润色文本…", target: nil, action: nil)
        let resumeBtn = NSButton(title: "恢复未发工作", target: nil, action: nil)
        let copyRawBtn = NSButton(title: "复制原转写", target: nil, action: nil)
        let coachBtn = NSButton(title: "下载带教结果…", target: nil, action: nil)
        let zipBtn = NSButton(title: "下载整条 ZIP…", target: nil, action: nil)
        let favoriteBtn = NSButton(title: "收藏带教建议", target: nil, action: nil)
        let clearBtn = NSButton(title: "清空语音历史…", target: nil, action: nil)

        self.buttons = [
            "audio": audioBtn,
            "cancel": cancelBtn,
            "delete": deleteBtn,
            "raw": rawBtn,
            "copy": copyBtn,
            "retry": retryBtn,
            "manual": manualBtn,
            "repolish": repolishBtn,
            "polished": polishedBtn,
            "details": detailsBtn,
            "resume": resumeBtn,
            "copyRaw": copyRawBtn,
            "coach": coachBtn,
            "zip": zipBtn,
            "favorite": favoriteBtn,
            "clear": clearBtn,
            "recovery": recoveryBtn,
            "all": allBtn
        ]

        super.init(frame: frameRect)
        setupUI(historyTable: historyTable, copyBtn: copyBtn, detailsBtn: detailsBtn, manualBtn: manualBtn, allBtn: allBtn, recoveryBtn: recoveryBtn)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(historyTable: HistoryTableView, copyBtn: NSButton, detailsBtn: NSButton, manualBtn: NSButton, allBtn: NSButton, recoveryBtn: NSButton) {
        translatesAutoresizingMaskIntoConstraints = false

        hiddenProxyContainer.isHidden = true
        hiddenProxyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hiddenProxyContainer)
        for (key, button) in buttons {
            if key != "copy" && key != "details" && key != "manual" && key != "all" && key != "recovery" {
                hiddenProxyContainer.addSubview(button)
            }
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.title = ""
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 116
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "waveform.slash", accessibilityDescription: nil)!)
        emptyIcon.contentTintColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let emptyTitle = NSTextField(labelWithString: "暂无语音历史记录")
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)

        let emptySubtitle = NSTextField(labelWithString: "在任意输入框按 Fn 唤起录音，转写和润色结果将显示在此。")
        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        emptyStateView.addArrangedSubview(emptyIcon)
        emptyStateView.addArrangedSubview(emptyTitle)
        emptyStateView.addArrangedSubview(emptySubtitle)
        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scrollView)
        listContainer.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyStateView.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor)
        ])

        historyTable.onDataChanged = { [weak self] in
            guard let self else { return }
            self.emptyStateView.isHidden = self.table.numberOfRows > 0
        }
        emptyStateView.isHidden = table.numberOfRows > 0

        recoverySummary.font = .systemFont(ofSize: 12)
        recoverySummary.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        recoverySummary.maximumNumberOfLines = 2
        recoverySummary.translatesAutoresizingMaskIntoConstraints = false

        message.font = .systemFont(ofSize: 12)
        message.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        message.maximumNumberOfLines = 2
        message.translatesAutoresizingMaskIntoConstraints = false

        recoveryContainer.orientation = .vertical
        recoveryContainer.alignment = .leading
        recoveryContainer.spacing = 8
        recoveryContainer.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView(views: [allBtn, recoveryBtn])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false

        setupMenus()

        let leftActions = NSStackView(views: [copyBtn, detailsBtn, manualBtn])
        leftActions.orientation = .horizontal
        leftActions.spacing = 10
        leftActions.alignment = .centerY

        let rightActions = NSStackView(views: [downloadPopUp, morePopUp])
        rightActions.orientation = .horizontal
        rightActions.spacing = 10
        rightActions.alignment = .centerY

        let actionBar = NSView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(leftActions)
        actionBar.addSubview(rightActions)
        leftActions.translatesAutoresizingMaskIntoConstraints = false
        rightActions.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftActions.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
            leftActions.topAnchor.constraint(equalTo: actionBar.topAnchor),
            leftActions.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor),

            rightActions.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            rightActions.topAnchor.constraint(equalTo: actionBar.topAnchor),
            rightActions.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor)
        ])

        let mainStack = NSStackView(views: [topBar, recoverySummary, recoveryContainer, listContainer, message, actionBar])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            listContainer.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            recoverySummary.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            recoveryContainer.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            message.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            actionBar.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func setupMenus() {
        downloadPopUp.translatesAutoresizingMaskIntoConstraints = false
        downloadPopUp.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let downloadMenu = NSMenu()
        let downloadHeader = NSMenuItem(title: "下载产物 ▾", action: nil, keyEquivalent: "")
        downloadMenu.addItem(downloadHeader)

        let downloads: [(String, String)] = [
            ("下载音频…", "audio"),
            ("下载转写…", "raw"),
            ("下载润色文本…", "polished"),
            ("下载带教结果…", "coach"),
            ("下载整条 ZIP…", "zip")
        ]
        for (title, key) in downloads {
            if key == "zip" { downloadMenu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            downloadMenu.addItem(item)
        }
        downloadPopUp.menu = downloadMenu

        morePopUp.translatesAutoresizingMaskIntoConstraints = false
        morePopUp.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let moreMenu = NSMenu()
        let moreHeader = NSMenuItem(title: "更多操作 ▾", action: nil, keyEquivalent: "")
        moreMenu.addItem(moreHeader)

        let mores: [(String, String, Bool)] = [
            ("复制原转写", "copyRaw", false),
            ("仅重新润色", "repolish", false),
            ("显式重试转写", "retry", false),
            ("恢复未发工作", "resume", false),
            ("收藏带教建议", "favorite", true),
            ("取消片段", "cancel", false),
            ("删除历史…", "delete", true),
            ("清空语音历史…", "clear", false)
        ]
        for (title, key, sep) in mores {
            let item = NSMenuItem(title: title, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            moreMenu.addItem(item)
            if sep { moreMenu.addItem(.separator()) }
        }
        morePopUp.menu = moreMenu
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let button = buttons[key] else { return }
        button.performClick(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let key = menuItem.representedObject as? String,
              let button = buttons[key] else { return menuItem.isEnabled }
        return button.isEnabled && !button.isHidden
    }
}

@MainActor
final class HistoryRecordCellView: NSTableCellView {
    private let cardView = NSView()
    private let contentLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 14
        cardView.layer?.borderWidth = 1.0
        cardView.layer?.borderColor = NSColor(red: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0).cgColor
        cardView.layer?.backgroundColor = NSColor.white.cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        contentLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        contentLabel.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
        contentLabel.maximumNumberOfLines = 3
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(contentLabel)

        metaLabel.font = .systemFont(ofSize: 12, weight: .regular)
        metaLabel.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            contentLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 22),
            contentLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -22),
            contentLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),

            metaLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 22),
            metaLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -22),
            metaLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
            metaLabel.topAnchor.constraint(greaterThanOrEqualTo: contentLabel.bottomAnchor, constant: 8)
        ])
    }

    func configure(date: String, duration: String, text: String, status: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            contentLabel.stringValue = "（无转写文本 · 纯音频记录）"
            contentLabel.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        } else {
            contentLabel.stringValue = trimmed
            contentLabel.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
        }

        var metaParts: [String] = []
        if !date.isEmpty { metaParts.append(date) }
        if !duration.isEmpty { metaParts.append(duration) }
        if !status.isEmpty { metaParts.append(status) }
        metaLabel.stringValue = metaParts.joined(separator: "  ·  ")

        updateSelectionState()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        updateSelectionState()
    }

    private func updateSelectionState() {
        let isSelected = (superview as? NSTableRowView)?.isSelected ?? false
        if isSelected {
            cardView.layer?.borderColor = NSColor(red: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 0.85).cgColor
            cardView.layer?.borderWidth = 1.5
            cardView.layer?.backgroundColor = NSColor(red: 0xF7/255.0, green: 0xF9/255.0, blue: 0xFF/255.0, alpha: 1.0).cgColor
        } else {
            cardView.layer?.borderColor = NSColor(red: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0).cgColor
            cardView.layer?.borderWidth = 1.0
            cardView.layer?.backgroundColor = NSColor.white.cgColor
        }
    }
}

private final class HistoryTableView: NSTableView {
    var onDataChanged: (() -> Void)?

    override func reloadData() {
        super.reloadData()
        onDataChanged?()
    }
}

private final class HistoryActionButton: NSButton {
    enum Style { case primary, secondary }
    let style: Style

    init(title: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.setButtonType(.momentaryPushIn)
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.font = .systemFont(ofSize: 13, weight: style == .primary ? .semibold : .medium)
        self.translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override var title: String {
        didSet { updateAppearance() }
    }

    override var intrinsicContentSize: NSSize {
        let original = super.intrinsicContentSize
        return NSSize(width: max(original.width + 24, 88), height: 36)
    }

    private func updateAppearance() {
        guard let layer = self.layer else { return }
        let textColor: NSColor
        if style == .primary {
            layer.backgroundColor = isEnabled
                ? NSColor(red: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 1.0).cgColor
                : NSColor(red: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 0.35).cgColor
            layer.borderWidth = 0
            textColor = .white
        } else {
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderWidth = 1.0
            layer.borderColor = NSColor(red: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0).cgColor
            textColor = isEnabled
                ? NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
                : NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 0.5)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: textColor,
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: style == .primary ? .semibold : .medium),
            .paragraphStyle: paragraph
        ])
    }
}

private final class HistoryFilterButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        self.setButtonType(.momentaryPushIn)
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 6
        self.layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1.0).cgColor
        self.font = .systemFont(ofSize: 12, weight: .medium)
        self.translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override var intrinsicContentSize: NSSize {
        let original = super.intrinsicContentSize
        return NSSize(width: original.width + 16, height: 28)
    }

    private func updateAppearance() {
        let textColor = isEnabled
            ? NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
            : NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 0.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: textColor,
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .paragraphStyle: paragraph
        ])
    }
}
