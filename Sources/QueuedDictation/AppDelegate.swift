import AppKit
@preconcurrency import ApplicationServices
import DictationCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RecordingApplication
    private let microphone: MicrophoneCapture
    private var mainWindow: MainWindowController!
    private var embeddedViews: [String: NSView] = [:]
    private var permissionsWindow: NSWindow?
    private let serviceSettings: ServiceSettings
    private let serviceCredentials: any ServiceCredentialStoring
    private let polishSettings: PolishSettings
    private let coachSettings: CoachSettings
    private let polishClient: PolishClient
    private let resourceSettings: ResourceSettings
    private let historyRetentionSettings: HistoryRetentionSettings
    private let favoritesStore: FavoritesStore
    private let textDelivery: CrossAppTextDelivery
    private let deliverySettings: DeliverySettings
    private var deliverySettingsWindow: DeliverySettingsWindowController?
    private var resourceSettingsWindow: ResourceSettingsWindowController?
    private var historyRetentionSettingsWindow: HistoryRetentionSettingsWindowController?
    private var favoritesWindow: FavoritesWindowController?
    private var deliveryConfigurationFailure: String?
    private let hotkeySession: HotkeyApplicationSession
    private var recordingCapsule: HotkeyRecordingCapsule?
    private var hotkeySettings: HotkeySettingsWindowController?
    private var queueWindowController: QueueWindowController?
    private var polishSettingsWindow: PolishSettingsWindowController?
    private var coachSettingsWindow: CoachSettingsWindowController?
    private var coachPanel: CoachPanelWindowController?
    private var coachActionFailure: String?
    private var hotkeyReadiness: NSTextField?
    private var historyPage: HistoryPageView?
    private var transcriptionPage: TranscriptionSettingsView?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var microphoneLabel: NSTextField?
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
    private var repolishButton: NSButton?
    private var polishedDownloadButton: NSButton?
    private var coachDownloadButton: NSButton?
    private var zipDownloadButton: NSButton?
    private var favoriteHistoryButton: NSButton?
    private var clearHistoryButton: NSButton?
    private var historyMessage: NSTextField?
    private var historyDetailsButton: NSButton?
    private var resumeHistoryButton: NSButton?
    private var recoveryActions: RecoveryActionsView?
    private var recoverySummary: NSTextField?
    private var recoveryItems: [RecoveryItem] = []
    private var recoveryFailure: String?
    private var showingRecovery = false
    private var refreshingRecovery = false
    private var manualInsertButton: NSButton?
    private var manualConfirmButton: NSButton?
    private var historyDetailsWindow: NSWindow?
    private var historyDetailsText: NSTextView?
#if NATIVE_ACCEPTANCE
    private let nativeEnvironment: NativeAcceptanceEnvironment
#endif

    override init() {
        let microphone = MicrophoneCapture()
        self.microphone = microphone
#if NATIVE_ACCEPTANCE
        let environment = NativeAcceptanceEnvironment.required()
        nativeEnvironment = environment
        let root = environment.vault
        let settingsDirectory = environment.settings
#else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QueuedDictation", isDirectory: true)
        let settingsDirectory = root.deletingLastPathComponent().appendingPathComponent("QueuedDictationSettings")
#endif
        serviceSettings = ServiceSettings(file: settingsDirectory.appendingPathComponent("services.json"))
#if NATIVE_ACCEPTANCE
        serviceCredentials = environment.credentials
#else
        serviceCredentials = KeychainServiceCredentials()
#endif
        polishSettings = PolishSettings(file: settingsDirectory.appendingPathComponent("polish.json"))
        coachSettings = CoachSettings(file: settingsDirectory.appendingPathComponent("coach.json"))
        resourceSettings = ResourceSettings(file: settingsDirectory.appendingPathComponent("resources.json"))
        historyRetentionSettings = HistoryRetentionSettings(file: settingsDirectory.appendingPathComponent("history-retention.json"))
#if NATIVE_ACCEPTANCE
        do { try environment.initialize(service: serviceSettings, polish: polishSettings, coach: coachSettings) }
        catch { fatalError("Native acceptance setup failed; production storage was not opened.") }
        polishClient = PolishClient(settings: polishSettings, services: serviceSettings, credentials: serviceCredentials, networkConfiguration: environment.network)
#else
        polishClient = PolishClient(settings: polishSettings, services: serviceSettings, credentials: serviceCredentials)
#endif
        deliverySettings = DeliverySettings(file: settingsDirectory.appendingPathComponent("delivery.json"))
        textDelivery = CrossAppTextDelivery()
        do { textDelivery.updateConfiguration(try deliverySettings.load()) }
        catch {
            textDelivery.automaticDeliveryEnabled = false
            deliveryConfigurationFailure = error.localizedDescription
        }
#if NATIVE_ACCEPTANCE
        let dataKeys = environment.dataKeys
        let recording = RecordingApplication(source: microphone, historyDirectory: root, keys: dataKeys,
            transcription: TranscriptionDependencies(settings: serviceSettings, credentials: serviceCredentials, networkConfiguration: environment.network, delivery: textDelivery),
            polish: polishClient, coach: CoachDependencies(settings: coachSettings, services: serviceSettings, credentials: serviceCredentials, networkConfiguration: environment.network),
            resourceSettings: resourceSettings, historyRetentionSettings: historyRetentionSettings)
#else
        let dataKeys = KeychainDataKey()
        let recording = RecordingApplication(source: microphone, historyDirectory: root, keys: dataKeys,
                                     transcription: TranscriptionDependencies(settings: serviceSettings, credentials: serviceCredentials, delivery: textDelivery),
                                     polish: polishClient, coach: CoachDependencies(settings: coachSettings, services: serviceSettings, credentials: serviceCredentials),
                                     resourceSettings: resourceSettings, historyRetentionSettings: historyRetentionSettings)
#endif
        model = recording
        favoritesStore = FavoritesStore(vaultRoot: root, keys: dataKeys,
            maximumLocalBytes: { [resourceSettings] in try resourceSettings.load().maximumLocalBytes },
            reservedBytes: { [weak recording] in
                guard let recording else { throw FavoritesError.storageUnavailable }
                return try recording.reservedStorageBytes
            })
#if NATIVE_ACCEPTANCE
        hotkeySession = HotkeyApplicationSession(recording: recording, listener: GlobalHotkeyListener(), settings: HotkeyConfigurationStore(defaults: environment.defaults))
#else
        hotkeySession = HotkeyApplicationSession(recording: recording, listener: GlobalHotkeyListener(), settings: HotkeyConfigurationStore())
#endif
        super.init()
        favoritesStore.onChange = { [weak self] in
            guard let self else { return }
            self.model.invalidateStorageUsage()
            if self.mainWindow?.isShowing(.favorites) == true { self.favoritesWindow?.reload() }
            self.resourceSettingsWindow?.renderRuntimeStatus()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow = MainWindowController()
        mainWindow.onSelect = { [weak self] page in
            switch page {
            case .history: self?.showHistory()
            case .queue: self?.showQueue()
            case .models: self?.showModelSettings()
            case .coach: self?.showCoachSettings()
            case .favorites: self?.showFavorites()
            case .settings: self?.showSettings()
            }
        }
        mainWindow.onLeavePage = { [weak self] in self?.hotkeySettings?.endEditing() }
        mainWindow.onToggleRecording = { [weak self] in self?.hotkeySession.controller.toggleRecordingFromApp() }
        installApplicationMenu()
        let capsule = HotkeyRecordingCapsule()
        capsule.onCancel = { [weak self] in self?.hotkeySession.controller.cancelCurrentRecording() }
        capsule.onFinish = { [weak self] in self?.hotkeySession.controller.toggleRecordingFromApp() }
        capsule.onToggleCoach = { [weak self] in self?.toggleCoach() }
        recordingCapsule = capsule
        if let scheduler = model.coachScheduler { coachPanel = makeCoachPanel(scheduler) }
        hotkeySession.onChange = { [weak self] in self?.renderHotkeys() }
        model.onChange = { [weak self] in
#if NATIVE_ACCEPTANCE
            if let self { self.nativeEnvironment.observe(self.model, hotkey: self.hotkeySession.controller.configuration) }
#endif
            self?.render()
        }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.terminating else { return }
                self.hotkeySession.checkConditions()
#if NATIVE_ACCEPTANCE
                self.nativeEnvironment.observe(self.model, hotkey: self.hotkeySession.controller.configuration)
#endif
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        render()
#if NATIVE_ACCEPTANCE
        nativeEnvironment.boot()
        nativeEnvironment.observe(model, hotkey: hotkeySession.controller.configuration)
        showHistory()
#else
        if !UserDefaults.standard.bool(forKey: "didDismissIntroduction") { showModelSettings() }
        else { showHistory() }
#endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !terminating else { return }
        render()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        timer?.invalidate()
        hotkeySession.beginTermination()
        if !hotkeySession.requiresTerminationWait {
            hotkeySession.shutdown()
            return .terminateNow
        }
        Task {
            await hotkeySession.finishForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeySession.onChange = nil
        model.onChange = nil
        favoritesStore.onChange = nil
        hotkeySession.shutdown()
        recordingCapsule?.orderOut(nil)
        coachPanel?.window?.orderOut(nil)
        timer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.reopen()
        return true
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 Queued Dictation", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let quit = NSMenuItem(title: "退出 Queued Dictation", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        let editMenu = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                    ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                    ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        NSApp.mainMenu = menu
    }

    private func showEmbedded(_ window: NSWindow?, key: String, page: MainWindowController.Page, subtitle: String,
                              tabs: [String] = [], selectedTab: Int = 0, onTab: ((Int) -> Void)? = nil) {
        let content: NSView
        if let cached = embeddedViews[key] { content = cached }
        else {
            guard let original = window?.contentView else { return }
            content = original
            window?.contentView = nil
            embeddedViews[key] = content
        }
        mainWindow.show(page, subtitle: subtitle, content: content, tabTitles: tabs, selectedTab: selectedTab, onTab: onTab)
    }

    private let settingsTabs = ["快捷键", "权限", "文本上屏", "队列与存储", "历史保留"]
    private func selectSettingsTab(_ index: Int) {
        switch index {
        case 0: showHotkeySettings()
        case 1: showPermissions()
        case 2: showDeliverySettings()
        case 3: showResourceSettings()
        case 4: showHistoryRetentionSettings()
        default: break
        }
    }

    private func showSettingsContent(_ window: NSWindow?, key: String, tab: Int) {
        showEmbedded(window, key: key, page: .settings, subtitle: "调整录音、输入与本地保存方式。", tabs: settingsTabs, selectedTab: tab,
                     onTab: { [weak self] in self?.selectSettingsTab($0) })
    }

    @objc private func showSettings() { showHotkeySettings() }

    private func showPermissions() {
        if permissionsWindow == nil {
            let page = PermissionsSettingsView(frame: NSRect(x: 0, y: 0, width: 800, height: 540))
            let window = NSWindow(contentRect: page.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            permissionsWindow = window
            microphoneLabel = page.microphoneStatus
            accessibilityLabel = page.accessibilityStatus
            hotkeyReadiness = page.hotkeyStatus
            page.microphoneButton.target = self
            page.microphoneButton.action = #selector(configureMicrophone)
            page.accessibilityButton.target = self
            page.accessibilityButton.action = #selector(configureAccessibility)
            page.hotkeyButton.target = self
            page.hotkeyButton.action = #selector(configureListening)
        }
        render()
        showSettingsContent(permissionsWindow, key: "permissions", tab: 1)
    }

    @objc private func showHistory() {
        showingRecovery = false
        presentHistory()
    }

    private func presentHistory() {
        if historyWindow == nil {
            let page = HistoryPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 660))
            historyPage = page
            let window = NSWindow(contentRect: page.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            historyWindow = window
            page.table.dataSource = self
            page.table.delegate = self
            table = page.table
            recoverySummary = page.recoverySummary
            historyMessage = page.message
            let actions: [(String, Selector)] = [
                ("audio", #selector(downloadAudio)), ("cancel", #selector(cancelHistory)), ("delete", #selector(deleteHistory)),
                ("raw", #selector(downloadRaw)), ("copy", #selector(copyCurrent)), ("retry", #selector(retryTranscription)),
                ("manual", #selector(showManualDelivery)), ("repolish", #selector(repolish)), ("polished", #selector(downloadPolished)),
                ("details", #selector(showHistoryDetails)), ("resume", #selector(resumeHistory)), ("copyRaw", #selector(copyRaw)),
                ("coach", #selector(downloadCoach)), ("zip", #selector(downloadHistoryZIP)), ("favorite", #selector(favoriteHistory)),
                ("clear", #selector(clearHistory)), ("recovery", #selector(showRecovery)), ("all", #selector(showHistory))
            ]
            for (key, action) in actions { page.buttons[key]?.target = self; page.buttons[key]?.action = action }
            downloadButton = page.buttons["audio"]
            cancelHistoryButton = page.buttons["cancel"]
            deleteButton = page.buttons["delete"]
            rawDownloadButton = page.buttons["raw"]
            copyButton = page.buttons["copy"]
            retryButton = page.buttons["retry"]
            manualButton = page.buttons["manual"]
            repolishButton = page.buttons["repolish"]
            polishedDownloadButton = page.buttons["polished"]
            historyDetailsButton = page.buttons["details"]
            resumeHistoryButton = page.buttons["resume"]
            coachDownloadButton = page.buttons["coach"]
            zipDownloadButton = page.buttons["zip"]
            favoriteHistoryButton = page.buttons["favorite"]
            clearHistoryButton = page.buttons["clear"]
            let recovery = RecoveryActionsView(onAction: { [weak self] id, action in
                guard let self, !self.terminating else { throw DictationError.applicationTerminating }
                switch action {
                case .resumeUnsent: try self.model.resumePendingProcessing(id)
                case .retryTranscription: try self.model.retryTranscription(id)
                case .retryPolish: try self.model.repolish(id)
                case .retryCoach: try self.model.retryCoach(id)
                }
                self.reloadHistory()
            })
            recoveryActions = recovery
            page.recoveryContainer.addArrangedSubview(recovery)
            recovery.widthAnchor.constraint(equalTo: page.recoveryContainer.widthAnchor).isActive = true
        }
        reloadHistory()
        showEmbedded(historyWindow, key: "history", page: .history, subtitle: "录音、转写、润色和带教结果，都在这里。")
    }

    @objc private func showRecovery() {
        showingRecovery = true
        presentHistory()
    }

    @objc private func showQueue() {
        if queueWindowController == nil { queueWindowController = QueueWindowController(model: model) }
        queueWindowController?.refresh()
        showEmbedded(queueWindowController?.window, key: "queue", page: .queue, subtitle: "按录音顺序交付；需要你处理的片段会保留在这里。")
    }

    @objc private func showPolishSettings() {
        if polishSettingsWindow == nil {
            polishSettingsWindow = PolishSettingsWindowController(settings: polishSettings, services: serviceSettings,
                credentials: serviceCredentials, client: polishClient, configurationChanged: { [weak self] in self?.sharedConfigurationChanged() })
        }
        polishSettingsWindow?.prepareEmbeddedView()
        showEmbedded(polishSettingsWindow?.window, key: "polish", page: .models, subtitle: "使用自己的模型服务，分别配置转写和润色。", tabs: ["转写服务", "润色"], selectedTab: 1,
                     onTab: { [weak self] index in if index == 0 { self?.showModelSettings() } else { self?.showPolishSettings() } })
    }

    @objc private func showResourceSettings() {
        if resourceSettingsWindow == nil {
            resourceSettingsWindow = ResourceSettingsWindowController(settings: resourceSettings, runtimeStatus: { [weak model] in
                guard let model else { return "" }
                do {
                    let usage = try model.queueUsage()
                    let local = try model.storageUsage(), reserved = try model.reservedStorageBytes
                    return "实际主积压：\(usage.segments) 段／\(Int(usage.duration)) 秒／\(usage.audioBytes) 字节；全数据目录 \(local) 字节；在途结果预留 \(reserved) 字节。主请求 \(model.mainRequestBudget.activeCount)／\(model.mainRequestBudget.limit)，带教 \(model.coachScheduler?.inFlightCount ?? 0)／\(model.coachScheduler?.configuration.concurrency ?? 3)。"
                } catch { return error.localizedDescription }
            }, configurationChanged: { [weak self] in self?.model.configurationChanged(); self?.render() })
        }
        resourceSettingsWindow?.renderRuntimeStatus()
        showSettingsContent(resourceSettingsWindow?.window, key: "resources", tab: 3)
    }

    @objc private func showHistoryRetentionSettings() {
        if historyRetentionSettingsWindow == nil {
            historyRetentionSettingsWindow = HistoryRetentionSettingsWindowController(settings: historyRetentionSettings,
                configurationChanged: { [weak self] in self?.reloadHistory(); self?.render() })
        }
        historyRetentionSettingsWindow?.prepareEmbeddedView()
        showSettingsContent(historyRetentionSettingsWindow?.window, key: "retention", tab: 4)
    }

    @objc private func showFavorites() {
        if favoritesWindow == nil {
            favoritesWindow = FavoritesWindowController(store: favoritesStore,
                storageChanged: { [weak model] in model?.invalidateStorageUsage() })
        }
        favoritesWindow?.reload()
        showEmbedded(favoritesWindow?.window, key: "favorites", page: .favorites, subtitle: "收藏的带教建议独立保存，不随历史清理。")
    }

    @objc private func showDeliverySettings() {
        if deliverySettingsWindow == nil { deliverySettingsWindow = DeliverySettingsWindowController(settings: deliverySettings, delivery: textDelivery) }
        deliverySettingsWindow?.render()
        showSettingsContent(deliverySettingsWindow?.window, key: "delivery", tab: 2)
    }

    @objc private func showCoachSettings() {
        model.configurationChanged()
        guard let scheduler = model.coachScheduler else { showError(model.coachConfigurationFailure ?? .invalidConfiguration); return }
        if coachSettingsWindow == nil {
            coachSettingsWindow = CoachSettingsWindowController(scheduler: scheduler, settings: coachSettings, services: serviceSettings,
                onOpenSharedServices: { [weak self] in self?.showPolishSettings() })
        }
        showEmbedded(coachSettingsWindow?.window, key: "coach", page: .coach, subtitle: "用独立模型提供英语建议，不影响正常输入。")
    }

    @objc private func toggleCoach() {
        guard !terminating else { return }
        coachActionFailure = nil
        model.configurationChanged()
        do {
            guard let scheduler = model.coachScheduler else { throw model.coachConfigurationFailure ?? CoachFailure.invalidConfiguration }
            try scheduler.setEnabled(!scheduler.configuration.enabled)
        } catch { coachActionFailure = (error as? CoachFailure)?.localizedDescription ?? "带教开关未能保存，请从设置检查本机配置。" }
        renderCoach()
    }

    private func sharedConfigurationChanged() {
        model.configurationChanged()
        if let servicePicker {
            do {
                updateTranscriptionServices(try serviceSettings.load().services,
                    selecting: servicePicker.selectedItem?.representedObject as? UUID)
            } catch { showError(error) }
        }
        polishSettingsWindow?.refreshSharedServices()
        coachSettingsWindow?.refreshSharedServices()
        refreshServiceReadiness()
        render()
    }

    @objc private func showModelSettings() {
        if settingsWindow == nil {
            let page = TranscriptionSettingsView(frame: NSRect(x: 0, y: 0, width: 840, height: 680))
            transcriptionPage = page
            let window = NSWindow(contentRect: page.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            settingsWindow = window
            servicePicker = page.servicePicker
            serviceName = page.serviceName
            baseURLField = page.baseURLField
            modelField = page.modelField
            keyField = page.keyField
            authPicker = page.authPicker
            timeoutField = page.timeoutField
            serviceReadiness = page.readiness
            servicePicker?.target = self
            servicePicker?.action = #selector(selectService)
            page.saveButton.target = self
            page.saveButton.action = #selector(saveService)
            page.deleteKeyButton.target = self
            page.deleteKeyButton.action = #selector(deleteServiceKey)
            page.historyButton.target = self
            page.historyButton.action = #selector(dismissIntroduction)
            loadSettings()
        }
        refreshServiceReadiness()
        render()
        showEmbedded(settingsWindow, key: "services", page: .models, subtitle: "使用自己的模型服务，分别配置转写和润色。", tabs: ["转写服务", "润色"], selectedTab: 0,
                     onTab: { [weak self] index in if index == 0 { self?.showModelSettings() } else { self?.showPolishSettings() } })
    }

    private func loadSettings() {
        do {
            let configuration = try serviceSettings.load()
            updateTranscriptionServices(configuration.services, selecting: configuration.transcription?.serviceID)
            modelField?.stringValue = configuration.transcription?.model ?? ""
            timeoutField?.stringValue = String(configuration.transcriptionTimeout)
            selectService()
        } catch { showError(error) }
        refreshServiceReadiness()
    }

    private func updateTranscriptionServices(_ services: [ModelService], selecting serviceID: UUID?) {
        configuredServices = services
        let menu = NSMenu()
        for service in services {
            let item = NSMenuItem(title: service.name, action: nil, keyEquivalent: "")
            item.representedObject = service.id
            menu.addItem(item)
        }
        let newService = NSMenuItem(title: "新增服务…", action: nil, keyEquivalent: "")
        newService.representedObject = NSNull()
        menu.addItem(newService)
        servicePicker?.menu = menu
        servicePicker?.select(menu.items.first { ($0.representedObject as? UUID) == serviceID && serviceID != nil } ?? newService)
    }

    @objc private func selectService() {
        let selectedID = servicePicker?.selectedItem?.representedObject as? UUID
        let service = configuredServices.first { $0.id == selectedID }
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
            sharedConfigurationChanged()
            loadSettings()
        } catch { showError(error); refreshServiceReadiness() }
    }

    @objc private func deleteServiceKey() {
        do { try serviceSettings.deleteServiceKey(for: editingServiceID, credentials: serviceCredentials); sharedConfigurationChanged() }
        catch { showError(error) }
    }
    private func refreshServiceReadiness() {
        switch model.transcriptionReadiness {
        case .missingConfiguration: serviceReadiness?.stringValue = "尚未配置转写服务和模型；有效录音会加密保存并等待配置。"
        case .missingCredentials: serviceReadiness?.stringValue = "所选转写服务需要 API 密钥；有效录音会保存并等待补齐配置。"
        case .some(let failure): serviceReadiness?.stringValue = failure.localizedDescription
        case .none: serviceReadiness?.stringValue = "转写配置齐全；实际文件请求成功前，该角色能力尚未验证。"
        }
    }
    @objc private func configureListening() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func configureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleRecording() {
        hotkeySession.controller.toggleRecordingFromApp()
    }

    @objc private func cancelRecording() { hotkeySession.controller.cancelCurrentRecording() }

    @objc private func showHotkeySettings() {
        if hotkeySettings == nil { hotkeySettings = HotkeySettingsWindowController(session: hotkeySession) }
        hotkeySettings?.render()
        showSettingsContent(hotkeySettings?.window, key: "hotkeys", tab: 0)
    }

    @objc private func configureMicrophone() {
        if model.microphoneAuthorization == .notDetermined {
            Task { await model.requestMicrophoneAccess() }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func dismissIntroduction() {
#if NATIVE_ACCEPTANCE
        nativeEnvironment.defaults.set(true, forKey: "didDismissIntroduction")
#else
        UserDefaults.standard.set(true, forKey: "didDismissIntroduction")
#endif
        showHistory()
    }

    @objc private func downloadAudio() {
        downloadHistory(.audio)
    }

    @objc private func cancelHistory() {
        guard let entry = selectedEntry else { return }
        do { try model.cancelRecordedSegment(entry.id); reloadHistory() }
        catch { showError(error) }
    }

    @objc private func downloadRaw() {
        downloadHistory(.rawTranscription)
    }
    @objc private func copyRaw() {
        guard let entry = selectedEntry else { return }
        do { try model.copyRawTranscription(entry.id) }
        catch { showError(error) }
    }
    @objc private func copyCurrent() {
        guard let entry = selectedEntry else { return }
        do { try model.copyCurrentText(entry.id) }
        catch { showError(error) }
    }
    @objc private func repolish() {
        guard let entry = selectedEntry else { return }
        do { try model.repolish(entry.id); reloadHistory() }
        catch { showError(error) }
    }
    @objc private func resumeHistory() {
        guard let entry = selectedEntry else { return }
        do { try model.resumePendingProcessing(entry.id); reloadHistory() }
        catch { showError(error) }
    }
    @objc private func downloadPolished() {
        downloadHistory(.polishedText)
    }
    @objc private func downloadCoach() { downloadHistory(.coachResult) }
    @objc private func downloadHistoryZIP() { downloadHistory(nil) }

    private func downloadHistory(_ item: HistoryExportItem?) {
        guard let entry = selectedEntry, let window = mainWindow.window else { return }
        let panel = NSSavePanel()
        switch item {
        case .audio?: panel.allowedContentTypes = [.wav]
        case .rawTranscription?, .polishedText?: panel.allowedContentTypes = [.plainText]
        case .coachResult?: panel.allowedContentTypes = [.json]
        case nil: panel.allowedContentTypes = [.zip]
        }
        panel.nameFieldStringValue = "\(entry.id.uuidString.prefix(8))-\(item?.fileName ?? "history.zip")"
        panel.message = "主动下载的文件包含所选语音片段的明文产物；ZIP 仅包含实际已有产物。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    if let item { try await self.model.exportHistoryItem(item, for: entry.id, to: url) }
                    else { try await self.model.exportHistoryZIP(entry.id, to: url) }
                    self.historyMessage?.stringValue = "已下载所选产物。"
                } catch { self.showError(error) }
            }
        }
    }

    @objc private func favoriteHistory() {
        guard let entry = selectedEntry else { return }
        defer { model.invalidateStorageUsage() }
        do {
            try favoritesStore.save(try model.favoriteSnapshot(for: entry.id))
            historyMessage?.stringValue = "已收藏带教建议与对应文本。"
        } catch { showError(error) }
    }
    @objc private func showHistoryDetails() {
        guard let entry = selectedEntry else { return }
        if historyDetailsWindow == nil {
            let (window, stack) = makeWindow(title: "语音片段文本与带教", size: NSSize(width: 700, height: 550))
            historyDetailsWindow = window
            let text = NSTextView()
            text.isEditable = false; text.isRichText = false; text.font = .systemFont(ofSize: 14)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true; scroll.documentView = text
            scroll.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 490)])
            historyDetailsText = text
        }
        var sections = ["片段 \(entry.id.uuidString.prefix(8))"]
        if let text = entry.rawTranscription { sections.append("原始转写\n\(text)") }
        if let text = entry.polishedText { sections.append("已保存润色文本\n\(text)") }
        if let failure = entry.polish?.failure { sections.append(failure.localizedDescription) }
        if let result = entry.coach?.result {
            let mode = entry.coach?.dispatch?.audioUsed == true ? "原音频带教" : "文本带教（无音频，不评价流利度）"
            switch result {
            case .noCard: sections.append("\(mode)：本段无需卡片。")
            case .card(let feedback):
                sections.append("\(mode)\n" + feedback.suggestions.map { suggestion in
                    var lines: [String] = []
                    if !suggestion.original.isEmpty { lines.append("原表达：\(suggestion.original)") }
                    if let evidence = suggestion.audioEvidence {
                        lines.append("音频依据：\(evidence.startSeconds)–\(evidence.endSeconds) 秒\n观察：\(evidence.observation)")
                    }
                    lines.append("建议：\(suggestion.improved)\n原因：\(suggestion.reason)")
                    return lines.joined(separator: "\n")
                }.joined(separator: "\n\n"))
            }
        }
        if let failure = entry.coach?.failure { sections.append(failure.localizedDescription) }
        historyDetailsText?.string = sections.joined(separator: "\n\n")
        present(historyDetailsWindow!)
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
            manualInsertButton = button("插入当前光标", #selector(insertManual))
            manualConfirmButton = button("确认本段已粘贴", #selector(confirmManual))
            stack.addArrangedSubview(horizontal([manualInsertButton!, manualConfirmButton!]))
            stack.addArrangedSubview(label("复制不会标记完成。写回不确定时，请检查目标后明确确认。"))
        }
        refreshManualDelivery()
        manualWindow?.orderFrontRegardless()
    }

    private func refreshManualDelivery() {
        guard let id = manualID else { return }
        let history: [VoiceHistoryEntry]
        do { history = try model.history() }
        catch {
            manualInsertButton?.isEnabled = false
            manualConfirmButton?.isEnabled = false
            manualLabel?.stringValue = operationFailureMessage(error)
            return
        }
        guard let entry = history.first(where: { $0.id == id }),
              entry.disposition == .awaitingProcessing, entry.rawTranscription != nil else {
            manualWindow?.close(); manualID = nil; return
        }
        let uncertain = entry.delivery == .uncertain || recoveryItems.first(where: { $0.id == id })?.deliveryUncertain == true
        manualInsertButton?.isEnabled = !uncertain && !terminating
        manualConfirmButton?.isEnabled = !terminating
        manualLabel?.stringValue = uncertain
            ? "片段 \(id.uuidString.prefix(8)) 写回不确定：请先检查原目标，只在确认本段已粘贴后点击确认。不能再次插入。"
            : "片段 \(id.uuidString.prefix(8))：请自行切到目标输入框并选定光标，再点击插入。旧目标不会自动恢复；请先处理队头，复制不会放行队列。"
    }
    @objc private func insertManual() {
        guard let id = manualID, manualInsertButton?.isEnabled == true else { return }
        do {
            let result = try model.insertCurrentTextAtCurrentCursor(id)
            reloadHistory()
            if result == .delivered { manualWindow?.close() }
            else { manualLabel?.stringValue = result == .uncertain ? "写回结果无法确认，请检查目标并确认本段已粘贴；不会再次插入。" : "没有可确认的 可写输入框，请检查辅助功能权限并自行选定输入位置，也可从历史复制。" }
        }
        catch { manualLabel?.stringValue = operationFailureMessage(error) }
    }
    @objc private func confirmManual() {
        guard let id = manualID, manualConfirmButton?.isEnabled == true else { return }
        do { try model.confirmManuallyDelivered(id); manualWindow?.close(); reloadHistory() }
        catch { manualLabel?.stringValue = operationFailureMessage(error) }
    }

    @objc private func deleteHistory() {
        guard let entry = selectedEntry, let window = mainWindow.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除这条语音历史？"
        alert.informativeText = "该片段的本机音频、文本和带教结果将被删除，相关处理和交付会停止。带教收藏与已下载文件保留。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.model.deleteHistory(entry.id); self.reloadHistory() }
            catch { self.showError(error) }
        }
    }

    @objc private func clearHistory() {
        guard let window = mainWindow.window, !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部语音历史？"
        alert.informativeText = "已保存历史的音频、文本和带教结果将被删除，相关处理和交付会停止。带教收藏与已下载文件保留；当前正在采集的录音不受影响。"
        alert.addButton(withTitle: "清空语音历史")
        alert.addButton(withTitle: "保留")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.model.clearHistory(); self.reloadHistory() }
            catch { self.showError(error) }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func render() {
        resourceSettingsWindow?.renderRuntimeStatus()
        deliverySettingsWindow?.render()
        hotkeySession.synchronize()
        microphoneLabel?.stringValue = "麦克风：\(authorizationString(model.microphoneAuthorization))"
        if !textDelivery.automaticDeliveryEnabled {
            accessibilityLabel?.stringValue = "文本上屏配置未就绪：" + (deliveryConfigurationFailure ?? "请打开文本上屏设置重新保存。")
        } else { accessibilityLabel?.stringValue = textDelivery.accessibilityAuthorized ? "辅助功能：已允许；仍须目标未变化才自动交付。" : "辅助功能：未允许，保留转写供手动复制和下载。" }
        renderHotkeys()
        renderCoach()
        if model.state == .ready, mainWindow.isShowing(.history) { reloadHistory() }
        queueWindowController?.refresh()
    }

    private func renderRecordingState() {
        let status: String
        switch model.state {
        case .ready:
            status = hotkeySession.controller.isTransitioning
                ? (hotkeySession.controller.presentation == .starting ? "正在启动录音…" : "正在结束录音…")
                : model.microphoneAuthorization == .authorized ? "就绪" : "麦克风未授权"
            mainWindow?.renderRecordingAction(title: "开始录音", enabled: !hotkeySession.controller.isTransitioning && !terminating)
        case .requestingMicrophone:
            status = "等待麦克风授权"
            mainWindow?.renderRecordingAction(title: "等待授权", enabled: false)
        case .recording(_, let duration):
            status = "正在录音 · \(durationString(duration))"
            mainWindow?.renderRecordingAction(title: "结束录音", enabled: hotkeySession.presentation != .finishing && !terminating)
        }
        mainWindow?.renderStatus([status, model.notice, coachFailureMessage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func renderHotkeys() {
        renderRecordingState()
        let controller = hotkeySession.controller
        let shortcutName: String
        switch controller.configuration.binding {
        case .fn: shortcutName = "Fn"
        case .combination(let combination): shortcutName = combination.displayName
        }
        mainWindow?.renderShortcut(name: shortcutName, toggle: controller.configuration.gesture == .tapToToggle)
        recordingCapsule?.render(hotkeySession.presentation, cancellation: controller.listenerStatus.cancellation, inputLevel: microphone.inputLevel)
        hotkeySettings?.render()
        let readiness: String
        if let error = hotkeySession.configurationError {
            readiness = error + " 快捷键已暂停；App 录音入口仍可使用。"
        } else {
            switch controller.listenerStatus.recording {
            case .ready:
                readiness = controller.configuration.binding == .fn ? "Fn / Globe 已就绪。" : "录音组合键已注册。"
            case .inactive: readiness = "快捷键监听已暂停；App 录音入口仍可使用。"
            case .unavailable(let reason): readiness = reason
            }
        }
        hotkeyReadiness?.stringValue = readiness
        recordingCapsule?.renderCoach(enabled: model.coachScheduler?.configuration.enabled == true, failure: coachFailureMessage)
    }

    private var coachFailureMessage: String? {
        coachActionFailure ?? model.coachConfigurationFailure?.localizedDescription ?? model.coachFailure?.localizedDescription
    }

    private func renderCoach() {
        let scheduler = model.coachScheduler
        coachSettingsWindow?.synchronizeEnabled()
        let enabled = scheduler?.configuration.enabled == true
        recordingCapsule?.renderCoach(enabled: enabled, failure: coachFailureMessage)
        if coachPanel == nil, let scheduler { coachPanel = makeCoachPanel(scheduler) }
        coachPanel?.render()
    }

    private func makeCoachPanel(_ scheduler: CoachWorkScheduler) -> CoachPanelWindowController {
        CoachPanelWindowController(scheduler: scheduler,
            currentInputScreen: { [weak textDelivery] in textDelivery?.currentInputScreen },
            onFavorite: { [weak self] card in
                guard let self else { throw FavoritesError.storageUnavailable }
                defer { self.model.invalidateStorageUsage() }
                try self.favoritesStore.save(try self.model.favoriteSnapshot(for: card))
            })
    }

    private func reloadHistory() {
        let selection = selectedEntry?.id
        refreshRecovery()
        do {
            let history = try model.history()
            let recovering = Set(recoveryItems.map(\.id))
            entries = showingRecovery ? history.filter { recovering.contains($0.id) } : history
            table?.reloadData()
            if let selection, let row = entries.firstIndex(where: { $0.id == selection }) {
                table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else if showingRecovery, !entries.isEmpty {
                table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            updateSelection()
            if manualWindow?.isVisible == true { refreshManualDelivery() }
        }
        catch { entries = []; table?.reloadData(); updateSelection(); showError(error) }
    }

    private func refreshRecovery() {
        guard !refreshingRecovery else { return }
        refreshingRecovery = true
        defer { refreshingRecovery = false }
        do { recoveryItems = try model.recoveryItems(); recoveryFailure = nil }
        catch { recoveryItems = []; recoveryFailure = operationFailureMessage(error) }
        var lines: [String] = []
        if let recoveryFailure { lines.append("恢复清单暂时无法读取：\(recoveryFailure)") }
        if let notice = model.recoveryNotice { lines.append(notice) }
        if showingRecovery, recoveryFailure == nil {
            lines.append(recoveryItems.isEmpty ? "当前没有待恢复片段。" : "\(recoveryItems.count) 段待恢复。请选择片段，再决定继续、显式重试或手动取用。")
        }
        recoverySummary?.stringValue = lines.joined(separator: "\n")
    }

    private var selectedEntry: VoiceHistoryEntry? {
        guard let row = table?.selectedRow, entries.indices.contains(row) else { return nil }
        return entries[row]
    }

    private func updateSelection() {
        let entry = selectedEntry
        let recovery = recoveryItems.first { $0.id == entry?.id }
        recoveryActions?.render(recovery, terminating: terminating)
        var exports: [HistoryExportItem] = []
        if let entry {
            do { exports = try model.availableHistoryExports(entry.id) }
            catch { historyMessage?.stringValue = operationFailureMessage(error) }
        }
        downloadButton?.isEnabled = exports.contains(.audio)
        deleteButton?.isEnabled = selectedEntry != nil
        cancelHistoryButton?.isEnabled = selectedEntry?.disposition == .awaitingProcessing
        rawDownloadButton?.isEnabled = exports.contains(.rawTranscription)
        copyButton?.isEnabled = entry?.rawTranscription != nil
        retryButton?.isEnabled = entry?.disposition == .awaitingProcessing && entry?.rawTranscription == nil && entry?.transcription?.status != .inFlight
        retryButton?.isHidden = recovery != nil
        manualButton?.isEnabled = entry?.disposition == .awaitingProcessing && entry?.rawTranscription != nil
        manualButton?.title = recovery?.deliveryUncertain == true || entry?.delivery == .uncertain ? "检查并确认交付…" : "手动交付…"
        repolishButton?.isEnabled = entry?.rawTranscription != nil && entry?.disposition != .cancelled && entry?.polish?.status != .inFlight && !terminating
        repolishButton?.isHidden = recovery != nil
        polishedDownloadButton?.isEnabled = exports.contains(.polishedText)
        coachDownloadButton?.isEnabled = exports.contains(.coachResult)
        zipDownloadButton?.isEnabled = !exports.isEmpty
        if case .card? = entry?.coach?.result, let entry, !terminating {
            favoriteHistoryButton?.isEnabled = (try? model.favoriteSnapshot(for: entry.id)) != nil
        }
        else { favoriteHistoryButton?.isEnabled = false }
        clearHistoryButton?.isEnabled = !entries.isEmpty && !terminating
        historyDetailsButton?.isEnabled = entry?.rawTranscription != nil || entry?.coach?.result != nil
        resumeHistoryButton?.isEnabled = entry?.disposition != .cancelled && (entry?.queueStage == .waitingForResume || entry?.coach?.status == .waitingForResume) && !terminating
        resumeHistoryButton?.isHidden = recovery != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        var text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = entry.recordedAt.formatted(date: .numeric, time: .standard)
        case "duration": text = durationString(entry.duration)
        default:
            if let recovery = recoveryItems.first(where: { $0.id == entry.id }),
               recovery.canResumeUnsent || recovery.needsTranscriptionRetry || recovery.needsPolishRetry || recovery.needsCoachRetry || recovery.deliveryUncertain {
                var states: [String] = []
                if recovery.canResumeUnsent { states.append("未发工作待继续") }
                if recovery.needsTranscriptionRetry { states.append("转写待显式重试") }
                if recovery.needsPolishRetry { states.append("润色待显式重试") }
                if recovery.needsCoachRetry { states.append("带教待显式重试") }
                if recovery.deliveryUncertain { states.append("交付不确定，须检查并确认") }
                text = states.joined(separator: " · ")
            }
            else if entry.disposition == .cancelled { text = "已取消 · 已有产物保留" }
            else if entry.queueStage == .waitingForResume { text = "未发工作超期，等待主动恢复 · 已有产物保留" }
            else if entry.disposition == .completed {
                if let failure = entry.polish?.failure {
                    text = (entry.polishedText == nil ? "已交付原转写 · 未润色：" : "已交付 · 本次润色未成功：") + failure.localizedDescription
                } else { text = "已交付 · 已有产物保留" }
            }
            else if let failure = entry.transcription?.failure { text = failure.localizedDescription }
            else if entry.transcription?.status == .inFlight { text = "转写请求中 · 可继续录下一段" }
            else if entry.queueStage == .waitingForResume { text = "未发工作已超出自动发送时间窗 · 请主动恢复" }
            else if let failure = entry.polish?.failure { text = failure.localizedDescription }
            else if entry.polish?.status == .inFlight { text = "润色请求中 · 带教和后续录音独立" }
            else if entry.queueStage == .waitingForPolishSlot { text = "原转写已保存 · 润色等待主请求槽位" }
            else if entry.delivery == .uncertain { text = "写回不确定 · 请检查并手动确认" }
            else if entry.rawTranscription != nil { text = "转写已保存 · 待手动交付" }
            else { text = "待处理 · 音频已保存" }
        }
        if tableColumn?.identifier.rawValue != "date", tableColumn?.identifier.rawValue != "duration", entry.interruptedRecording == true {
            text = "中断录音 · " + text
        }
        if tableColumn?.identifier.rawValue == "history" {
            let cell = HistoryRecordCellView()
            cell.configure(date: entry.recordedAt.formatted(date: .numeric, time: .shortened),
                           duration: durationString(entry.duration),
                           text: entry.polishedText ?? entry.rawTranscription ?? "音频已保存，等待转写结果。",
                           status: text)
            return cell
        }
        return label(text)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = operationFailureMessage(error)
        alert.addButton(withTitle: "好")
        if let window = mainWindow.window, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    private func operationFailureMessage(_ error: Error) -> String {
        (error as? DictationError)?.localizedDescription ?? (error as? TranscriptionFailure)?.localizedDescription
            ?? (error as? PolishFailure)?.localizedDescription ?? (error as? CoachFailure)?.localizedDescription
            ?? (error as? FavoritesError)?.localizedDescription ?? (error as? HistoryExportError)?.localizedDescription
            ?? (error as? HistoryRetentionSettingsError)?.localizedDescription ?? "本机文件操作失败，请检查目录、钥匙串访问与可用空间。"
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
        if title == "模型服务" {
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
                                     title == "模型服务" ? stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20) : stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
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
