import AppKit
import DictationCore

@MainActor
final class QueueWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RecordingApplication
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let concurrency = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retry = NSButton(title: "重试转写", target: nil, action: nil)
    private let copyText = NSButton(title: "复制原文", target: nil, action: nil)
    private let manual = NSButton(title: "手动上屏…", target: nil, action: nil)
    private let skip = NSButton(title: "跳过主交付", target: nil, action: nil)
    private let cancel = NSButton(title: "取消片段", target: nil, action: nil)
    private var segments: [QueueSegment] = []
    private var manualPanel: QueueManualPanel?
    private var manualLabel: NSTextField?
    private var insertButton: NSButton?
    private var confirmButton: NSButton?
    private var manualID: UUID?

    init(model: RecordingApplication) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "待交付队列"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 420)
        window.center()
        concurrency.addItems(withTitles: (1...10).map { String($0) })
        concurrency.target = self
        concurrency.action = #selector(changeConcurrency)
        let budget = NSStackView(views: [NSTextField(labelWithString: "主流程请求并发（转写与润色共用）"), concurrency])
        budget.spacing = 12
        for (title, id, width) in [("开始序", "order", 75.0), ("录音时间", "date", 180.0), ("时长", "duration", 70.0), ("状态", "stage", 350.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 30
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (button, action) in [(retry, #selector(retrySelected)), (copyText, #selector(copySelected)),
                                 (manual, #selector(showManual)), (skip, #selector(skipSelected)), (cancel, #selector(cancelSelected))] {
            button.target = self
            button.action = action
        }
        let actions = NSStackView(views: [retry, copyText, manual, skip, cancel])
        actions.spacing = 8
        reason.maximumNumberOfLines = 3
        reason.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString: "只有队头可上屏。复制不会放行；成功插入、确认已粘贴、跳过或取消才允许后段继续。录完取消和跳过都保留已有历史与音频。")
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [summary, budget, scroll, reason, actions, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reason.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
            if let selectedID, let index = segments.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            updateSelection()
            refreshManual()
        } catch { reason.stringValue = error.localizedDescription }
    }

    private var selected: QueueSegment? { segments.indices.contains(table.selectedRow) ? segments[table.selectedRow] : nil }
    private func updateSelection() {
        let item = selected
        retry.isEnabled = item != nil && item?.stage != .recording && item?.stage != .transcribing && item?.hasText == false
        copyText.isEnabled = item?.hasText == true
        manual.isEnabled = item?.hasText == true && item?.isHead == true
        skip.isEnabled = item != nil && item?.stage != .recording
        cancel.isEnabled = item != nil
        reason.stringValue = item?.reason ?? (item == nil ? "选择一个片段查看状态及可用操作。" : "")
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func numberOfRows(in tableView: NSTableView) -> Int { segments.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = segments[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "order": text = item.recordingOrder.map(String.init) ?? "旧记录"
        case "date": text = item.recordedAt.formatted(date: .numeric, time: .standard)
        case "duration": text = durationString(item.duration)
        default: text = (item.isHead ? "队头 · " : "") + item.stage.title
        }
        return NSTextField(labelWithString: text)
    }

    @objc private func changeConcurrency() {
        do { try model.updateProcessingConfiguration(ProcessingConfiguration(maximumConcurrentMainRequests: concurrency.indexOfSelectedItem + 1)); refresh() }
        catch { reason.stringValue = error.localizedDescription }
    }
    @objc private func retrySelected() { operate { try self.model.retryTranscription($0) } }
    @objc private func copySelected() { operate { try self.model.copyRawTranscription($0) } }
    @objc private func skipSelected() { operate { try self.model.skipMainDelivery($0) } }
    @objc private func cancelSelected() {
        guard let selected else { return }
        if selected.stage == .recording {
            Task { await model.cancelCurrentRecording(); refresh() }
        } else { operate { try self.model.cancelRecordedSegment($0) } }
    }
    private func operate(_ action: (UUID) throws -> Void) {
        guard let selected else { return }
        do { try action(selected.id); refresh() }
        catch { reason.stringValue = error.localizedDescription }
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
            let insert = NSButton(title: "插入当前 TextEdit 光标", target: self, action: #selector(insertManual))
            let confirm = NSButton(title: "确认本段已在外部粘贴", target: self, action: #selector(confirmManual))
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
                label.widthAnchor.constraint(equalTo: stack.widthAnchor)
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
        guard let item = segments.first(where: { $0.id == manualID }), item.isHead, item.hasText else { manualPanel?.close(); self.manualID = nil; return }
        insertButton?.isEnabled = item.stage != .deliveryUncertain
        confirmButton?.isEnabled = true
        manualLabel?.stringValue = "片段 \(manualID.uuidString.prefix(8))：请自行选定 TextEdit 光标后点击插入；此面板不抢输入焦点。写回不确定时只可检查并确认本段已粘贴。"
    }
    @objc private func insertManual() {
        guard let manualID else { return }
        do {
            let result = try model.insertRawTranscriptionAtCurrentCursor(manualID)
            refresh()
            if result == .delivered { manualPanel?.close() }
            else { manualLabel?.stringValue = result == .uncertain ? "写回结果无法确认，请检查目标并确认；不能重复插入。" : "当前没有可可靠判断的 TextEdit 输入框，请检查权限和目标。" }
        } catch { manualLabel?.stringValue = error.localizedDescription }
    }
    @objc private func confirmManual() {
        guard let manualID else { return }
        do { try model.confirmManuallyDelivered(manualID); manualPanel?.close(); refresh() }
        catch { manualLabel?.stringValue = error.localizedDescription }
    }
    private func durationString(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

private final class QueueManualPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
