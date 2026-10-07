import AppKit
import DictationCore

@MainActor
final class QueueWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RecordingApplication
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let concurrency = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retry = QueueActionButton(title: "重试转写", style: .secondary)
    private let resume = QueueActionButton(title: "恢复未发工作", style: .secondary)
    private let copyText = QueueActionButton(title: "复制文本", style: .secondary)
    private let manual = QueueActionButton(title: "手动上屏…", style: .primary)
    private let skip = QueueActionButton(title: "跳过主交付", style: .secondary)
    private let cancel = QueueActionButton(title: "取消片段", style: .secondary)
    private let emptyStateView = NSStackView()
    private var segments: [QueueSegment] = []
    private var manualPanel: QueueManualPanel?
    private var manualLabel: NSTextField?
    private var insertButton: NSButton?
    private var confirmButton: NSButton?
    private var manualID: UUID?

    init(model: RecordingApplication) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "待交付队列"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 460)
        window.backgroundColor = NSColor(red: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1.0)
        window.center()

        concurrency.addItems(withTitles: (1...10).map { String($0) })
        concurrency.target = self
        concurrency.action = #selector(changeConcurrency)

        let concurrencyLabel = NSTextField(labelWithString: "主流程请求并发限制（转写与润色共用）：")
        concurrencyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        concurrencyLabel.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)

        let budget = NSStackView(views: [concurrencyLabel, concurrency])
        budget.orientation = .horizontal
        budget.spacing = 10
        budget.alignment = .centerY

        summary.font = .systemFont(ofSize: 12)
        summary.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        let topCard = NSView()
        topCard.wantsLayer = true
        topCard.layer?.cornerRadius = 14
        topCard.layer?.borderWidth = 1.0
        topCard.layer?.borderColor = NSColor(red: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0).cgColor
        topCard.layer?.backgroundColor = NSColor.white.cgColor
        topCard.translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView(views: [budget, summary])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topCard.addSubview(topStack)

        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -18),
            topStack.topAnchor.constraint(equalTo: topCard.topAnchor, constant: 14),
            topStack.bottomAnchor.constraint(equalTo: topCard.bottomAnchor, constant: -14)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queue"))
        column.title = ""
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 104
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil)!)
        emptyIcon.contentTintColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let emptyTitle = NSTextField(labelWithString: "待交付队列为空")
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)

        let emptySubtitle = NSTextField(labelWithString: "当前所有录音已交付完毕，后续录音将依序进入队列处理。")
        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        emptyStateView.addArrangedSubview(emptyIcon)
        emptyStateView.addArrangedSubview(emptyTitle)
        emptyStateView.addArrangedSubview(emptySubtitle)
        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scroll)
        listContainer.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyStateView.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor)
        ])

        for (button, action) in [(retry, #selector(retrySelected)), (resume, #selector(resumeSelected)), (copyText, #selector(copySelected)),
                                 (manual, #selector(showManual)), (skip, #selector(skipSelected)), (cancel, #selector(cancelSelected))] {
            button.target = self
            button.action = action
        }

        let actions = NSStackView(views: [manual, copyText, retry, resume, skip, cancel])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY

        reason.maximumNumberOfLines = 2
        reason.font = .systemFont(ofSize: 12)
        reason.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        let help = NSTextField(wrappingLabelWithString: "只有队头可上屏。复制不会放行；成功插入、确认已粘贴、跳过或取消才允许后段继续。录完取消和跳过都保留已有历史与音频。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)

        let stack = NSStackView(views: [topCard, listContainer, reason, actions, help])
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

            topCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            reason.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.heightAnchor.constraint(equalToConstant: 38),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let selectedID = selected?.id
        do {
            segments = try model.queue()
            let usage = try model.queueUsage()
            summary.stringValue = "主积压 \(usage.segments) 段 · \(durationString(usage.duration)) · \(String(format: "%.1f", Double(usage.audioBytes) / 1_024 / 1_024)) MiB 音频；在途请求 \(model.mainRequestBudget.activeCount) / \(model.mainRequestBudget.limit)。"
            concurrency.selectItem(at: try model.processingConfiguration.maximumConcurrentMainRequests - 1)
            table.reloadData()
            emptyStateView.isHidden = !segments.isEmpty
            if let selectedID, let index = segments.firstIndex(where: { $0.id == selectedID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            updateSelection()
            refreshManual()
        } catch {
            reason.stringValue = error.localizedDescription
        }
    }

    private var selected: QueueSegment? {
        segments.indices.contains(table.selectedRow) ? segments[table.selectedRow] : nil
    }

    private func updateSelection() {
        let item = selected
        retry.isEnabled = item != nil && item?.stage != .recording && item?.stage != .transcribing && item?.hasText == false
        resume.isEnabled = item?.stage == .waitingForResume
        copyText.isEnabled = item?.hasText == true
        manual.isEnabled = item?.hasText == true && item?.isHead == true
        skip.isEnabled = item != nil && item?.stage != .recording
        cancel.isEnabled = item != nil
        reason.stringValue = item?.reason ?? (item == nil ? "选择一个片段查看状态及可用操作。" : "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        segments.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard segments.indices.contains(row) else { return nil }
        let item = segments[row]
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("queueCell"), owner: self) as? QueueSegmentCellView)
            ?? QueueSegmentCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("queueCell")
        cell.configure(segment: item, text: nil, durationString: durationString(item.duration))
        return cell
    }

    @objc private func changeConcurrency() {
        do {
            try model.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency.indexOfSelectedItem + 1))
            refresh()
        } catch {
            reason.stringValue = error.localizedDescription
        }
    }

    @objc private func retrySelected() { operate { try self.model.retryTranscription($0) } }
    @objc private func resumeSelected() { operate { try self.model.resumePendingProcessing($0) } }
    @objc private func copySelected() { operate { try self.model.copyCurrentText($0) } }
    @objc private func skipSelected() { operate { try self.model.skipMainDelivery($0) } }
    @objc private func cancelSelected() {
        guard let selected else { return }
        if selected.stage == .recording {
            Task { await model.cancelCurrentRecording(); refresh() }
        } else {
            operate { try self.model.cancelRecordedSegment($0) }
        }
    }

    private func operate(_ action: (UUID) throws -> Void) {
        guard let selected else { return }
        do {
            try action(selected.id)
            refresh()
        } catch {
            reason.stringValue = error.localizedDescription
        }
    }

    @objc private func showManual() {
        guard let selected, selected.isHead, selected.hasText else { return }
        manualID = selected.id
        if manualPanel == nil {
            let panel = QueueManualPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 180),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "队头手动上屏"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.center()

            let label = NSTextField(wrappingLabelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)

            let insert = QueueActionButton(title: "插入当前光标", style: .primary)
            insert.target = self
            insert.action = #selector(insertManual)

            let confirm = QueueActionButton(title: "确认本段已在外部粘贴", style: .secondary)
            confirm.target = self
            confirm.action = #selector(confirmManual)

            let buttons = NSStackView(views: [insert, confirm])
            buttons.spacing = 12

            let stack = NSStackView(views: [label, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false

            panel.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
                label.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.heightAnchor.constraint(equalToConstant: 38)
            ])

            manualPanel = panel
            manualLabel = label
            insertButton = insert
            confirmButton = confirm
        }
        refreshManual()
        manualPanel?.orderFrontRegardless()
    }

    private func refreshManual() {
        guard let manualID else { return }
        guard let item = segments.first(where: { $0.id == manualID }), item.isHead, item.hasText else {
            manualPanel?.close()
            self.manualID = nil
            return
        }
        insertButton?.isEnabled = item.stage != .deliveryUncertain
        confirmButton?.isEnabled = true
        manualLabel?.stringValue = "片段 \(manualID.uuidString.prefix(8))：请自行选定目标输入框光标后点击插入；此面板不抢输入焦点。写回不确定时只可检查并确认本段已粘贴。"
    }

    @objc private func insertManual() {
        guard let manualID else { return }
        do {
            let result = try model.insertCurrentTextAtCurrentCursor(manualID)
            refresh()
            if result == .delivered {
                manualPanel?.close()
            } else {
                manualLabel?.stringValue = result == .uncertain ? "写回结果无法确认，请检查目标并确认；不能重复插入。" : "当前没有可可靠判断的输入框，请检查权限和目标。"
            }
        } catch {
            manualLabel?.stringValue = error.localizedDescription
        }
    }

    @objc private func confirmManual() {
        guard let manualID else { return }
        do {
            try model.confirmManuallyDelivered(manualID)
            manualPanel?.close()
            refresh()
        } catch {
            manualLabel?.stringValue = error.localizedDescription
        }
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

@MainActor
final class QueueSegmentCellView: NSTableCellView {
    private let cardView = NSView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let stageLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(wrappingLabelWithString: "")
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")

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

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor(red: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 1.0)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(headerLabel)

        stageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stageLabel.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        stageLabel.alignment = .right
        stageLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stageLabel)

        contentLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        contentLabel.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
        contentLabel.maximumNumberOfLines = 2
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(contentLabel)

        reasonLabel.font = .systemFont(ofSize: 11)
        reasonLabel.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        reasonLabel.maximumNumberOfLines = 1
        reasonLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(reasonLabel)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            headerLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            headerLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: stageLabel.leadingAnchor, constant: -10),

            stageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            stageLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            contentLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            contentLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            contentLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),

            reasonLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            reasonLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            reasonLabel.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 4),
            reasonLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -12)
        ])
    }

    func configure(segment: QueueSegment, text: String?, durationString: String) {
        let orderText = segment.recordingOrder.map { "#\($0)" } ?? "旧记录"
        let prefix = segment.isHead ? "队头 · " : ""
        let dateText = segment.recordedAt.formatted(date: .numeric, time: .standard)
        headerLabel.stringValue = "\(prefix)\(orderText)  ·  \(dateText)  ·  \(durationString)"

        stageLabel.stringValue = segment.stage.title

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentLabel.stringValue = text
            contentLabel.textColor = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
        } else if segment.stage == .recording {
            contentLabel.stringValue = "（正在录音中…）"
            contentLabel.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        } else {
            contentLabel.stringValue = segment.hasText ? "文本已保存，可复制或手动交付。" : "音频已保存，等待转写结果。"
            contentLabel.textColor = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
        }

        if let reason = segment.reason, !reason.isEmpty {
            reasonLabel.stringValue = reason
            reasonLabel.isHidden = false
        } else {
            reasonLabel.stringValue = ""
            reasonLabel.isHidden = true
        }

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

private final class QueueManualPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class QueueActionButton: NSButton {
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
