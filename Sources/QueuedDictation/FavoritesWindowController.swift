import AppKit
import DictationCore
import UniformTypeIdentifiers

@MainActor
final class FavoritesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let store: FavoritesStore
    private let copyToPasteboard: (String) -> Bool
    private let storageChanged: @MainActor () -> Void
    private let table = NSTableView()
    private let detail = NSTextView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let copy = FavoriteActionButton(title: "复制文本", style: .primary)
    private let downloadPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let downloadText = NSButton(title: "下载文本…", target: nil, action: nil)
    private let downloadJSON = NSButton(title: "下载 JSON…", target: nil, action: nil)
    private let delete = FavoriteActionButton(title: "删除收藏…", style: .secondary)
    private let emptyStateView = NSStackView()
    private var favorites: [FavoriteFeedback] = []

    init(store: FavoritesStore, copyToPasteboard: @escaping (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }, storageChanged: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.copyToPasteboard = copyToPasteboard
        self.storageChanged = storageChanged

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "带教收藏"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
        window.backgroundColor = NSColor(red: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1.0)
        window.center()

        summary.font = .systemFont(ofSize: 12)
        summary.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        column.title = ""
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 92
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self

        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "star.slash", accessibilityDescription: nil)!)
        emptyIcon.contentTintColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let emptyTitle = NSTextField(labelWithString: "还没有带教收藏")
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)

        let emptySubtitle = NSTextField(labelWithString: "可从带教卡片或语音历史收藏建议，收藏的建议会独立保存在此。")
        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        emptyStateView.addArrangedSubview(emptyIcon)
        emptyStateView.addArrangedSubview(emptyTitle)
        emptyStateView.addArrangedSubview(emptySubtitle)
        listScroll.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor)
        ])

        let detailCard = NSView()
        detailCard.wantsLayer = true
        detailCard.layer?.cornerRadius = 14
        detailCard.layer?.borderWidth = 1.0
        detailCard.layer?.borderColor = NSColor(red: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0).cgColor
        detailCard.layer?.backgroundColor = NSColor.white.cgColor
        detailCard.translatesAutoresizingMaskIntoConstraints = false

        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailCard.addSubview(detailScroll)

        NSLayoutConstraint.activate([
            detailScroll.leadingAnchor.constraint(equalTo: detailCard.leadingAnchor, constant: 4),
            detailScroll.trailingAnchor.constraint(equalTo: detailCard.trailingAnchor, constant: -4),
            detailScroll.topAnchor.constraint(equalTo: detailCard.topAnchor, constant: 4),
            detailScroll.bottomAnchor.constraint(equalTo: detailCard.bottomAnchor, constant: -4)
        ])

        detail.isEditable = false
        detail.isSelectable = true
        detail.font = .systemFont(ofSize: 13.5)
        detail.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
        detail.textContainerInset = NSSize(width: 16, height: 14)
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true

        copy.target = self
        copy.action = #selector(copySelected)
        downloadText.target = self
        downloadText.action = #selector(exportSelectedText)
        downloadJSON.target = self
        downloadJSON.action = #selector(exportSelectedJSON)
        delete.target = self
        delete.action = #selector(deleteSelected)

        setupDownloadMenu()

        let actions = NSStackView(views: [copy, downloadPopUp, delete])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY

        let help = NSTextField(wrappingLabelWithString: "收藏保留对应文本与完整建议，直到你主动删除。删除或清空语音历史后仍可复习；原音频沿用语音历史的保留期。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        message.textColor = .systemRed
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 2

        let stack = NSStackView(views: [summary, listScroll, detailCard, actions, help, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listScroll.heightAnchor.constraint(equalToConstant: 220),
            detailCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            actions.heightAnchor.constraint(equalToConstant: 38),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    private func setupDownloadMenu() {
        downloadPopUp.translatesAutoresizingMaskIntoConstraints = false
        downloadPopUp.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let menu = NSMenu()
        let header = NSMenuItem(title: "下载导出 ▾", action: nil, keyEquivalent: "")
        menu.addItem(header)

        let itemText = NSMenuItem(title: "下载文本…", action: #selector(exportSelectedText), keyEquivalent: "")
        itemText.target = self
        itemText.representedObject = "text"
        menu.addItem(itemText)

        let itemJSON = NSMenuItem(title: "下载 JSON…", action: #selector(exportSelectedJSON), keyEquivalent: "")
        itemJSON.target = self
        itemJSON.representedObject = "json"
        menu.addItem(itemJSON)

        downloadPopUp.menu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return selected != nil
    }

    func present() {
        reload()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let selection = selected?.id
        do {
            favorites = try store.entries()
            summary.stringValue = favorites.isEmpty ? "还没有带教收藏。可从带教卡片或语音历史收藏建议。" : "\(favorites.count) 条带教收藏"
            message.stringValue = ""
        } catch {
            favorites = []
            summary.stringValue = "收藏暂时无法读取。"
            message.stringValue = failureMessage(error)
        }
        table.reloadData()
        emptyStateView.isHidden = !favorites.isEmpty
        if !favorites.isEmpty {
            let row = selection.flatMap { id in favorites.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        favorites.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard favorites.indices.contains(row) else { return nil }
        let favorite = favorites[row]
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("favoriteCell"), owner: self) as? FavoriteCardCellView)
            ?? FavoriteCardCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("favoriteCell")
        cell.configure(favorite: favorite)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    private var selected: FavoriteFeedback? {
        favorites.indices.contains(table.selectedRow) ? favorites[table.selectedRow] : nil
    }

    private func updateSelection() {
        var available = false
        if let favorite = selected {
            do {
                detail.string = try store.text(favorite.id)
                available = true
            } catch {
                detail.string = ""
                message.stringValue = failureMessage(error)
            }
        } else {
            detail.string = ""
        }
        copy.isEnabled = available
        downloadPopUp.isEnabled = available
        downloadText.isEnabled = available
        downloadJSON.isEnabled = available
        delete.isEnabled = available
    }

    @objc private func copySelected() {
        guard let favorite = selected else { return }
        do {
            guard copyToPasteboard(try store.text(favorite.id)) else {
                message.stringValue = "未能写入剪贴板，请重试。"
                return
            }
            message.stringValue = ""
        } catch {
            message.stringValue = failureMessage(error)
        }
    }

    @objc private func exportSelectedText() { exportSelected(json: false) }
    @objc private func exportSelectedJSON() { exportSelected(json: true) }

    private func exportSelected(json: Bool) {
        guard let favorite = selected, let window = table.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = json ? [.json] : [.plainText]
        panel.nameFieldStringValue = "带教收藏-\(favorite.id.uuidString.prefix(8)).\(json ? "json" : "txt")"
        panel.message = "下载文件包含这条收藏的明文文本和建议。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            do {
                if json { try self.store.exportJSON(favorite.id, to: destination) }
                else { try self.store.exportText(favorite.id, to: destination) }
                self.message.stringValue = ""
            } catch {
                self.message.stringValue = self.failureMessage(error)
            }
        }
    }

    @objc private func deleteSelected() {
        guard let favorite = selected, let window = table.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除这条带教收藏？"
        alert.informativeText = "该收藏的对应文本和建议将被删除。语音历史仍可单独管理。"
        alert.addButton(withTitle: "删除收藏")
        alert.addButton(withTitle: "保留")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            defer { self.storageChanged() }
            do {
                try self.store.delete(favorite.id)
                self.reload()
            } catch {
                self.message.stringValue = self.failureMessage(error)
            }
        }
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? FavoritesError)?.localizedDescription ?? "收藏操作未完成，请检查保存位置、钥匙串访问与可用空间。"
    }
}

@MainActor
final class FavoriteCardCellView: NSTableCellView {
    private let cardView = NSView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
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

        textLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        textLabel.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(textLabel)

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

            textLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            textLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            textLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),

            metaLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            metaLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            metaLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
            metaLabel.topAnchor.constraint(greaterThanOrEqualTo: textLabel.bottomAnchor, constant: 6)
        ])
    }

    func configure(favorite: FavoriteFeedback) {
        let cleanText = favorite.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        textLabel.stringValue = cleanText.isEmpty ? "（无文本内容）" : cleanText

        let dateStr = favorite.createdAt.formatted(date: .numeric, time: .shortened)
        let countStr = "\(favorite.feedback.suggestions.count) 条带教建议"
        metaLabel.stringValue = "\(dateStr)   ·   \(countStr)"

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

private final class FavoriteActionButton: NSButton {
    enum Style { case primary, secondary }
    let style: Style

    init(title: String, style: Style = .secondary) {
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
        return NSSize(width: max(original.width + 24, 84), height: 36)
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
