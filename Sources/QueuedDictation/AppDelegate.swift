import AppKit
import DictationCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RecordingApplication
    private let serviceSettings: ServiceSettings
    private let serviceCredentials: KeychainServiceCredentials
    private let textDelivery: TextEditDelivery
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
    private var servicePicker: NSPopUpButton?
    private var serviceName: NSTextField?
    private var baseURLField: NSTextField?
    private var modelField: NSTextField?
    private var keyField: NSSecureTextField?
    private var authPicker: NSPopUpButton?
    private var timeoutField: NSTextField?
    private var serviceReadiness: NSTextField?
    private var accessibilityLabel: NSTextField?
    private var configuredServices: [ModelService] = []
    private var editingServiceID = UUID()
    private var rawDownloadButton: NSButton?
    private var copyButton: NSButton?
    private var retryButton: NSButton?
    private var manualButton: NSButton?
    private var manualWindow: NSWindow?
    private var manualID: UUID?
    private var manualLabel: NSTextField?

    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QueuedDictation", isDirectory: true)
        serviceSettings = ServiceSettings(file: root.deletingLastPathComponent().appendingPathComponent("QueuedDictationSettings/services.json"))
        serviceCredentials = KeychainServiceCredentials()
        textDelivery = TextEditDelivery()
        model = RecordingApplication(source: MicrophoneCapture(), historyDirectory: root, keys: KeychainDataKey(),
                                     transcription: TranscriptionDependencies(settings: serviceSettings, credentials: serviceCredentials, delivery: textDelivery))
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

    func applicationWillTerminate(_ notification: Notification) { model.stopProcessing(); timer?.invalidate() }

    @objc private func showRecording() {
        if recordingWindow == nil {
            let (window, stack) = makeWindow(title: "录音", size: NSSize(width: 470, height: 290), nonactivating: true)
            recordingWindow = window
            recordingLabel = label("就绪", size: 22)
            stack.addArrangedSubview(recordingLabel!)
            stack.addArrangedSubview(label("请先把光标放在 TextEdit，再点击开始。单段最多 5 分钟。"))
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
        recordingWindow?.orderFrontRegardless()
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let (window, stack) = makeWindow(title: "语音历史", size: NSSize(width: 840, height: 460))
            historyWindow = window
            stack.addArrangedSubview(label("待处理片段不会因 30 天保留期被清理。取消片段仍可下载音频。"))
            let table = NSTableView()
            for (id, title, width) in [("date", "录音时间", 240.0), ("duration", "时长", 70.0), ("state", "状态", 470.0)] {
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
            rawDownloadButton = button("下载转写…", #selector(downloadRaw))
            copyButton = button("复制转写", #selector(copyRaw))
            retryButton = button("显式重试转写", #selector(retryTranscription))
            manualButton = button("手动交付…", #selector(showManualDelivery))
            stack.addArrangedSubview(horizontal([rawDownloadButton!, copyButton!, retryButton!, manualButton!]))
        }
        reloadHistory()
        present(historyWindow!)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let (window, stack) = makeWindow(title: "设置与权限", size: NSSize(width: 660, height: 640))
            settingsWindow = window
            stack.addArrangedSubview(label("先查看 App，随时补齐权限", size: 20))
            microphoneLabel = label("")
            stack.addArrangedSubview(microphoneLabel!)
            stack.addArrangedSubview(button("检查 / 设置麦克风权限", #selector(configureMicrophone)))
            accessibilityLabel = label("")
            stack.addArrangedSubview(accessibilityLabel!)
            stack.addArrangedSubview(button("设置辅助功能权限", #selector(configureAccessibility)))
            servicePicker = NSPopUpButton()
            servicePicker?.target = self
            servicePicker?.action = #selector(selectService)
            stack.addArrangedSubview(horizontal([label("共享服务"), servicePicker!]))
            serviceName = textField("服务名称")
            baseURLField = textField("https://example.com/v1 或 http://localhost:端口/v1")
            modelField = textField("所选服务的文件转写模型 ID")
            keyField = NSSecureTextField()
            keyField?.placeholderString = "新 API 密钥（空白保留；仅存钥匙串）"
            authPicker = NSPopUpButton()
            authPicker?.addItems(withTitles: ["Bearer API 密钥", "无鉴权（自管本地端点）"])
            timeoutField = textField("5–600 秒，默认 60")
            for (name, field) in [("服务名称", serviceName!), ("Base URL", baseURLField!), ("转写模型", modelField!), ("API 密钥", keyField!), ("整体截止（秒）", timeoutField!)] {
                stack.addArrangedSubview(horizontal([label(name), field]))
                field.widthAnchor.constraint(equalToConstant: 455).isActive = true
            }
            stack.addArrangedSubview(horizontal([label("服务鉴权"), authPicker!]))
            stack.addArrangedSubview(horizontal([button("保存转写配置", #selector(saveService)), button("删除所选服务密钥", #selector(deleteServiceKey))]))
            serviceReadiness = label("")
            serviceReadiness?.maximumNumberOfLines = 2
            serviceReadiness?.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(serviceReadiness!)
            let privacy = label("仅把本段音频和模型 ID 直发到所选 Base URL 的 /audio/transcriptions。成功的实际转写核验此角色；模型列表不作为能力证明。HTTP 本地连接的系统传输限制与局域网权限分别处理。")
            privacy.maximumNumberOfLines = 3; privacy.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(privacy)
            stack.addArrangedSubview(label("快捷键：当前通过 App 录音按钮开始和结束。"))
            stack.addArrangedSubview(button("稍后设置", #selector(dismissIntroduction)))
        }
        loadSettings()
        render()
        present(settingsWindow!)
    }

    private func loadSettings() {
        do {
            let configuration = try serviceSettings.load()
            configuredServices = configuration.services
            servicePicker?.removeAllItems()
            servicePicker?.addItems(withTitles: configuredServices.map(\.name) + ["新增服务…"])
            if let role = configuration.transcription,
               let index = configuredServices.firstIndex(where: { $0.id == role.serviceID }) {
                servicePicker?.selectItem(at: index)
                modelField?.stringValue = role.model
            } else { servicePicker?.selectItem(at: configuredServices.count); modelField?.stringValue = "" }
            timeoutField?.stringValue = String(Int(configuration.transcriptionTimeout))
            selectService()
        } catch { showError(error) }
        refreshServiceReadiness()
    }

    @objc private func selectService() {
        let index = servicePicker?.indexOfSelectedItem ?? -1
        let service = configuredServices.indices.contains(index) ? configuredServices[index] : nil
        editingServiceID = service?.id ?? UUID()
        serviceName?.stringValue = service?.name ?? ""
        baseURLField?.stringValue = service?.baseURL ?? ""
        authPicker?.selectItem(at: service?.authentication == ServiceAuthentication.none ? 1 : 0)
        keyField?.stringValue = ""
    }

    @objc private func saveService() {
        do {
            guard let timeout = TimeInterval(timeoutField?.stringValue ?? "") else { throw TranscriptionFailure.invalidConfiguration }
            let service = ModelService(id: editingServiceID, name: serviceName?.stringValue ?? "服务",
                                       baseURL: baseURLField?.stringValue ?? "", authentication: authPicker?.indexOfSelectedItem == 1 ? .none : .bearerToken)
            let key = keyField?.stringValue ?? ""
            try serviceSettings.saveTranscriptionService(service, model: modelField?.stringValue ?? "", timeout: timeout,
                                                        newKey: key.isEmpty ? nil : key, credentials: serviceCredentials)
            keyField?.stringValue = ""
            model.configurationChanged()
            loadSettings()
        } catch { showError(error); refreshServiceReadiness() }
    }

    @objc private func deleteServiceKey() {
        do { try serviceSettings.deleteServiceKey(for: editingServiceID, credentials: serviceCredentials); refreshServiceReadiness() }
        catch { showError(error) }
    }
    private func refreshServiceReadiness() {
        serviceReadiness?.stringValue = model.transcriptionReadiness?.localizedDescription ?? "转写配置齐全；实际文件请求成功前，该角色能力尚未验证。"
    }
    @objc private func configureAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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

    @objc private func downloadRaw() {
        guard let entry = selectedEntry, let window = historyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "转写-\(entry.id.uuidString.prefix(8)).txt"
        panel.message = "主动下载的转写是普通 UTF-8 文件。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.model.exportRawTranscription(entry.id, to: url) }
            catch { self.showError(error) }
        }
    }
    @objc private func copyRaw() {
        guard let entry = selectedEntry else { return }
        do { try model.copyRawTranscription(entry.id) }
        catch { showError(error) }
    }
    @objc private func retryTranscription() {
        guard let entry = selectedEntry else { return }
        do { try model.retryTranscription(entry.id); reloadHistory() }
        catch { showError(error) }
    }
    @objc private func showManualDelivery() {
        guard let entry = selectedEntry else { return }
        manualID = entry.id
        if manualWindow == nil {
            let (window, stack) = makeWindow(title: "手动交付", size: NSSize(width: 620, height: 210), nonactivating: true)
            manualWindow = window
            manualLabel = label("")
            manualLabel?.maximumNumberOfLines = 3; manualLabel?.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(manualLabel!)
            stack.addArrangedSubview(horizontal([button("插入当前 TextEdit 光标", #selector(insertManual)), button("确认本段已粘贴", #selector(confirmManual))]))
            stack.addArrangedSubview(label("复制不会标记完成。写回不确定时，请检查目标后明确确认。"))
        }
        manualLabel?.stringValue = "片段 \(entry.id.uuidString.prefix(8))：请自行切到 TextEdit 并选定光标，再点击插入。此面板不会切回目标；已取消或已完成片段不能插入。"
        manualWindow?.orderFrontRegardless()
    }
    @objc private func insertManual() {
        guard let id = manualID else { return }
        do {
            let result = try model.insertRawTranscriptionAtCurrentCursor(id)
            if result == .delivered { manualWindow?.close() }
            else { manualLabel?.stringValue = result == .uncertain ? "写回结果无法确认，请检查 TextEdit 并确认本段已粘贴；不会再次插入。" : "没有可确认的 TextEdit 可写目标，请检查辅助功能权限并自行选定输入位置，也可从历史复制。" }
            reloadHistory()
        }
        catch { manualLabel?.stringValue = error.localizedDescription }
    }
    @objc private func confirmManual() {
        guard let id = manualID else { return }
        do { try model.confirmManuallyDelivered(id); manualWindow?.close(); reloadHistory() }
        catch { manualLabel?.stringValue = error.localizedDescription }
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
        accessibilityLabel?.stringValue = textDelivery.accessibilityAuthorized ? "辅助功能：已允许；仍须目标未变化才自动交付。" : "辅助功能：未允许，保留转写供手动复制和下载。"
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
        let entry = selectedEntry
        rawDownloadButton?.isEnabled = entry?.rawTranscription != nil
        copyButton?.isEnabled = entry?.rawTranscription != nil
        retryButton?.isEnabled = entry?.disposition == .awaitingProcessing && entry?.rawTranscription == nil && entry?.transcription?.status != .inFlight
        manualButton?.isEnabled = entry?.disposition == .awaitingProcessing && entry?.rawTranscription != nil
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
            if entry.disposition == .cancelled { text = "已取消 · 已有产物保留" }
            else if entry.disposition == .completed { text = "已交付 · 已有产物保留" }
            else if let failure = entry.transcription?.failure { text = failure.localizedDescription }
            else if entry.transcription?.status == .inFlight { text = "转写请求中 · 可继续录下一段" }
            else if entry.delivery == .uncertain { text = "写回不确定 · 请检查并手动确认" }
            else if entry.rawTranscription != nil { text = "转写已保存 · 待手动交付" }
            else { text = "待处理 · 音频已保存" }
        }
        return label(text)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = (error as? DictationError)?.localizedDescription ?? (error as? TranscriptionFailure)?.localizedDescription ?? "本机文件操作失败，请检查目录与可用空间。"
        alert.addButton(withTitle: "好")
        if let window = historyWindow, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func textField(_ placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        return field
    }
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

    private func makeWindow(title: String, size: NSSize, nonactivating: Bool = false) -> (NSWindow, NSStackView) {
        let window: NSWindow
        if nonactivating {
            let panel = DictationPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.becomesKeyOnlyIfNeeded = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = panel
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        }
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content: NSView
        if title == "设置与权限" {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(scroll)
            NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
                                         scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
                                         scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
                                         scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
            content = SettingsDocumentView()
            content.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = content
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        } else { content = window.contentView! }
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                                     title == "设置与权限" ? stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20) : stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
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

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
