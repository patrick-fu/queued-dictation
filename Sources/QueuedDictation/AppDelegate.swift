import AppKit
import DictationCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RecordingApplication
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var recordingWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var recordingLabel: NSTextField?
    private var microphoneLabel: NSTextField?
    private var noticeLabel: NSTextField?
    private var startButton: NSButton?
    private var cancelButton: NSButton?
    private var downloadButton: NSButton?
    private var cancelHistoryButton: NSButton?
    private var deleteButton: NSButton?
    private var table: NSTableView?
    private var entries: [VoiceHistoryEntry] = []
    private var timer: Timer?
    private var terminating = false

    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QueuedDictation", isDirectory: true)
        model = RecordingApplication(source: MicrophoneCapture(), historyDirectory: root, keys: KeychainDataKey())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "就绪", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for (title, action) in [("录音…", #selector(showRecording)), ("语音历史…", #selector(showHistory)),
                                ("设置与权限…", #selector(showSettings)), ("退出 Queued Dictation", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        model.onChange = { [weak self] in self?.render() }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.checkRecordingConditions() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        render()
        if !UserDefaults.standard.bool(forKey: "didDismissIntroduction") { showSettings() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating || model.state == .ready { return .terminateNow }
        terminating = true
        Task {
            if model.state == .requestingMicrophone { await model.cancelCurrentRecording() }
            else { await model.finishRecording() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func showRecording() {
        if recordingWindow == nil {
            let (window, stack) = makeWindow(title: "录音", size: NSSize(width: 430, height: 270))
            recordingWindow = window
            recordingLabel = label("就绪", size: 22)
            stack.addArrangedSubview(recordingLabel!)
            stack.addArrangedSubview(label("单段最多 5 分钟。音频在本机加密保存。"))
            noticeLabel = label("")
            noticeLabel?.lineBreakMode = .byWordWrapping
            noticeLabel?.maximumNumberOfLines = 3
            stack.addArrangedSubview(noticeLabel!)
            startButton = button("开始录音", #selector(toggleRecording))
            cancelButton = button("取消当前录音", #selector(cancelRecording))
            stack.addArrangedSubview(horizontal([startButton!, cancelButton!]))
            stack.addArrangedSubview(button("打开语音历史", #selector(showHistory)))
        }
        render()
        present(recordingWindow!)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let (window, stack) = makeWindow(title: "语音历史", size: NSSize(width: 670, height: 410))
            historyWindow = window
            stack.addArrangedSubview(label("待处理片段不会因 30 天保留期被清理。取消片段仍可下载音频。"))
            let table = NSTableView()
            for (id, title, width) in [("date", "录音时间", 280.0), ("duration", "时长", 90.0), ("state", "状态", 180.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.width = width
                table.addTableColumn(column)
            }
            table.dataSource = self
            table.delegate = self
            table.rowHeight = 30
            table.allowsMultipleSelection = false
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.documentView = table
            scroll.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
                                         scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            self.table = table
            downloadButton = button("下载音频…", #selector(downloadAudio))
            cancelHistoryButton = button("取消片段", #selector(cancelHistory))
            deleteButton = button("删除历史…", #selector(deleteHistory))
            stack.addArrangedSubview(horizontal([downloadButton!, cancelHistoryButton!, deleteButton!]))
        }
        reloadHistory()
        present(historyWindow!)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let (window, stack) = makeWindow(title: "设置与权限", size: NSSize(width: 470, height: 330))
            settingsWindow = window
            stack.addArrangedSubview(label("先查看 App，随时补齐权限", size: 20))
            microphoneLabel = label("")
            stack.addArrangedSubview(microphoneLabel!)
            stack.addArrangedSubview(button("检查 / 设置麦克风权限", #selector(configureMicrophone)))
            stack.addArrangedSubview(label("转写服务：尚未配置。当前可录音并下载原音频。"))
            stack.addArrangedSubview(label("快捷键：当前通过 App 录音按钮开始和结束。"))
            stack.addArrangedSubview(label("自动上屏与带教：尚未配置。"))
            stack.addArrangedSubview(button("稍后设置", #selector(dismissIntroduction)))
        }
        render()
        present(settingsWindow!)
    }

    @objc private func toggleRecording() {
        Task {
            switch model.state {
            case .ready: await model.startRecording()
            case .recording: await model.finishRecording()
            case .requestingMicrophone: break
            }
        }
    }

    @objc private func cancelRecording() { Task { await model.cancelCurrentRecording() } }

    @objc private func configureMicrophone() {
        if model.microphoneAuthorization == .notDetermined {
            Task { await model.requestMicrophoneAccess() }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func dismissIntroduction() {
        UserDefaults.standard.set(true, forKey: "didDismissIntroduction")
        settingsWindow?.close()
    }

    @objc private func downloadAudio() {
        guard let entry = selectedEntry, let window = historyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "录音-\(entry.id.uuidString.prefix(8)).wav"
        panel.message = "主动下载的音频是普通文件，请选择合适的保存位置。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.model.exportAudio(entry.id, to: url) }
            catch { self.showError(error) }
        }
    }

    @objc private func cancelHistory() {
        guard let entry = selectedEntry else { return }
        do { try model.cancelRecordedSegment(entry.id); reloadHistory() }
        catch { showError(error) }
    }

    @objc private func deleteHistory() {
        guard let entry = selectedEntry, let window = historyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "删除这条语音历史？"
        alert.informativeText = "本机保存的音频将被删除。已下载的文件保留。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.model.deleteHistory(entry.id); self.reloadHistory() }
            catch { self.showError(error) }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func render() {
        let status: String
        switch model.state {
        case .ready:
            status = model.microphoneAuthorization == .authorized ? "就绪" : "麦克风未授权"
            startButton?.title = "开始录音"
            startButton?.isEnabled = true
            cancelButton?.isEnabled = false
        case .requestingMicrophone:
            status = "等待麦克风授权"
            startButton?.isEnabled = false
            cancelButton?.isEnabled = true
        case .recording(_, let duration):
            status = "正在录音 · \(durationString(duration))"
            startButton?.title = "结束并保存"
            startButton?.isEnabled = true
            cancelButton?.isEnabled = true
        }
        statusItem?.button?.title = model.state == .ready ? "QD" : "● QD"
        statusLine?.title = status
        recordingLabel?.stringValue = status
        noticeLabel?.stringValue = model.notice ?? ""
        microphoneLabel?.stringValue = "麦克风：\(authorizationString(model.microphoneAuthorization))"
        if model.state == .ready, historyWindow?.isVisible == true { reloadHistory() }
    }

    private func reloadHistory() {
        do { entries = try model.history(); table?.reloadData(); updateSelection() }
        catch { entries = []; table?.reloadData(); updateSelection(); showError(error) }
    }

    private var selectedEntry: VoiceHistoryEntry? {
        guard let row = table?.selectedRow, entries.indices.contains(row) else { return nil }
        return entries[row]
    }

    private func updateSelection() {
        downloadButton?.isEnabled = selectedEntry != nil
        deleteButton?.isEnabled = selectedEntry != nil
        cancelHistoryButton?.isEnabled = selectedEntry?.disposition == .awaitingProcessing
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = entry.recordedAt.formatted(date: .numeric, time: .standard)
        case "duration": text = durationString(entry.duration)
        default:
            text = switch entry.disposition {
            case .awaitingProcessing: "待处理 · 音频已保存"
            case .completed: "已完成"
            case .cancelled: "已取消 · 音频保留"
            }
        }
        return label(text)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = (error as? DictationError)?.localizedDescription ?? "本机文件操作失败，请检查目录与可用空间。"
        alert.addButton(withTitle: "好")
        if let window = historyWindow, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func label(_ text: String, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        return label
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 12
        return stack
    }

    private func makeWindow(title: String, size: NSSize) -> (NSWindow, NSStackView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                                     stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
        return (window, stack)
    }

    private func present(_ window: NSWindow) { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
    private func durationString(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    private func authorizationString(_ state: MicrophoneAuthorization) -> String {
        switch state {
        case .authorized: "已允许"
        case .notDetermined: "尚未询问（开始录音时可授权）"
        case .denied: "已拒绝，请在系统设置中恢复"
        case .restricted: "受系统限制"
        }
    }
}
