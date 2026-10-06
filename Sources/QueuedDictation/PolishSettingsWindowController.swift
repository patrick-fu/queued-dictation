import AppKit
import DictationCore

@MainActor
final class PolishSettingsWindowController: NSWindowController, NSTextViewDelegate {
    private enum ServiceSelection: Equatable { case service(UUID), none, new }
    private let settings: PolishSettings
    private let services: ServiceSettings
    private let credentials: any ServiceCredentialStoring
    private let client: PolishClient
    private let configurationChanged: @MainActor () -> Void
    private let enabled = NSButton(checkboxWithTitle: "启用润色", target: nil, action: nil)
    private let servicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let serviceName = NSTextField()
    private let baseURL = NSTextField()
    private let authentication = NSPopUpButton(frame: .zero, pullsDown: false)
    private let key = NSSecureTextField()
    private let model = NSTextField()
    private let timeout = NSTextField()
    private let prompt = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 210))
    private let status = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private var configuredServices: [ModelService] = []
    private var editingServiceID = UUID()
    // 自定义内容可能与升级后的默认相同，来源不能由文字相等推断。
    private var usesDefaultPrompt = true
    private var serviceSelection: ServiceSelection { servicePicker.selectedItem?.representedObject as? ServiceSelection ?? .none }
    private var selectedService: ModelService? {
        guard case .service(let id) = serviceSelection else { return nil }
        return configuredServices.first { $0.id == id }
    }

    init(settings: PolishSettings, services: ServiceSettings, credentials: any ServiceCredentialStoring,
         client: PolishClient, configurationChanged: @escaping @MainActor () -> Void) {
        self.settings = settings; self.services = services; self.credentials = credentials
        self.client = client; self.configurationChanged = configurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "润色设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
        window.center()
        servicePicker.target = self
        servicePicker.action = #selector(selectService)
        authentication.addItems(withTitles: ["Bearer API 密钥", "无鉴权（自管本地端点）"])
        serviceName.placeholderString = "共享服务名称"
        baseURL.placeholderString = "https://example.com/v1 或 http://localhost:端口/v1"
        key.placeholderString = "新 API 密钥（空白保留；仅存钥匙串）"
        model.placeholderString = "所选服务的 Chat 模型 ID"
        timeout.placeholderString = "5–600 秒，默认 30"
        prompt.isRichText = false
        prompt.font = .systemFont(ofSize: 13)
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.isVerticallyResizable = true
        prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]
        prompt.textContainer?.widthTracksTextView = true
        prompt.delegate = self
        let editor = NSScrollView()
        editor.hasVerticalScroller = true
        editor.borderType = .bezelBorder
        editor.documentView = prompt
        error.textColor = .systemRed
        let title = NSTextField(labelWithString: "整理本段转写，保留你的原意")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let sharing = NSTextField(wrappingLabelWithString: "多个角色可以使用同一共享服务。保存服务地址或密钥会影响使用它的角色；润色模型在下方单独保存。")
        let privacy = NSTextField(wrappingLabelWithString: "仅将本段原始转写和完整提示词直发到所选 Base URL 的 /chat/completions。配置齐全后仍需实际请求验证该角色能力。润色与转写共享请求并发。")
        privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            title, enabled, row("共享服务", servicePicker), sharing,
            row("服务名称", serviceName), row("Base URL", baseURL), row("服务鉴权", authentication), row("API 密钥", key),
            NSStackView(views: [button("保存共享服务", #selector(saveSharedService)), button("删除所选服务密钥", #selector(deleteServiceKey))]),
            row("润色模型", model), row("整体截止（秒）", timeout),
            NSTextField(labelWithString: "完整润色提示词"), editor,
            NSStackView(views: [button("保存润色设置", #selector(savePolishSettings)), button("恢复当前默认提示词", #selector(restorePrompt))]),
            status, error, privacy
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        let scroller = NSScrollView()
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroller)
        let document = PolishSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroller.documentView = document
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: content.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editor.heightAnchor.constraint(equalToConstant: 210)
        ])
        for label in [sharing, privacy, status, error] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { nil }

    private var didPrepareEmbeddedView = false
    func prepareEmbeddedView() {
        if !didPrepareEmbeddedView { loadSettings(); didPrepareEmbeddedView = true }
    }

    func showSettings() {
        prepareEmbeddedView()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func loadSettings() {
        do {
            let configuration = try settings.load()
            try refreshServices(selecting: configuration.role?.serviceID)
            enabled.state = configuration.enabled ? .on : .off
            model.stringValue = configuration.role?.model ?? ""
            timeout.stringValue = String(configuration.timeout)
            prompt.string = configuration.prompt
            usesDefaultPrompt = configuration.customPrompt == nil
            error.stringValue = ""
        } catch { showFailure(error) }
        renderReadiness()
    }

    func refreshSharedServices() {
        guard didPrepareEmbeddedView else { return }
        do { try refreshServices(selecting: selectedService?.id, preservingDraft: true) }
        catch { showFailure(error) }
        renderReadiness()
    }

    private func refreshServices(selecting serviceID: UUID?, preservingDraft: Bool = false) throws {
        let selection = preservingDraft ? serviceSelection : serviceID.map(ServiceSelection.service) ?? .none
        configuredServices = try services.load().services
        let menu = NSMenu()
        // addItems(withTitles:) 合并同标题；服务身份和特殊选项不由标题或数组位置推断。
        for service in configuredServices {
            let item = NSMenuItem(title: service.name, action: nil, keyEquivalent: "")
            item.representedObject = ServiceSelection.service(service.id)
            menu.addItem(item)
        }
        for (title, selection) in [("未选择服务", ServiceSelection.none), ("新增共享服务…", ServiceSelection.new)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = selection
            menu.addItem(item)
        }
        servicePicker.menu = menu
        let selected = menu.items.first { $0.representedObject as? ServiceSelection == selection }
            ?? menu.items.first { $0.representedObject as? ServiceSelection == ServiceSelection.none }
        servicePicker.select(selected)
        if !preservingDraft || serviceSelection != selection { selectService() }
    }

    @objc private func selectService() {
        let service = selectedService
        editingServiceID = service?.id ?? UUID()
        serviceName.stringValue = service?.name ?? ""
        baseURL.stringValue = service?.baseURL ?? ""
        authentication.selectItem(at: service?.authentication == ServiceAuthentication.none ? 1 : 0)
        key.stringValue = ""
        let canEditService = service != nil || serviceSelection == .new
        for field in [serviceName, baseURL, key] { field.isEnabled = canEditService }
        authentication.isEnabled = canEditService
        model.isEnabled = service != nil
    }

    @objc private func saveSharedService() {
        do {
            guard serviceSelection != .none else { throw PolishFailure.missingConfiguration }
            let service = ModelService(id: editingServiceID, name: serviceName.stringValue,
                baseURL: baseURL.stringValue, authentication: authentication.indexOfSelectedItem == 1 ? .none : .bearerToken)
            try services.saveService(service, newKey: key.stringValue.isEmpty ? nil : key.stringValue, credentials: credentials)
            key.stringValue = ""
            try refreshServices(selecting: service.id)
            error.stringValue = ""
            configurationChanged()
        } catch { showFailure(error) }
        renderReadiness()
    }

    @objc private func savePolishSettings() {
        do {
            guard let value = TimeInterval(timeout.stringValue) else { throw PolishFailure.invalidConfiguration }
            guard serviceSelection != .new else { throw PolishFailure.missingConfiguration }
            let role = selectedService.map { ModelRoleConfiguration(serviceID: $0.id, model: model.stringValue) }
            let configuration = PolishConfiguration(enabled: enabled.state == .on, role: role, timeout: value,
                customPrompt: usesDefaultPrompt ? nil : prompt.string)
            try settings.save(configuration)
            error.stringValue = ""
            configurationChanged()
        } catch { showFailure(error) }
        renderReadiness()
    }

    @objc private func restorePrompt() {
        do {
            var configuration = try settings.load()
            configuration.restoreDefaultPrompt()
            try settings.save(configuration)
            prompt.string = configuration.prompt
            usesDefaultPrompt = true
            error.stringValue = ""
            configurationChanged()
        } catch { showFailure(error) }
        renderReadiness()
    }

    @objc private func deleteServiceKey() {
        do {
            guard selectedService != nil else { throw PolishFailure.missingConfiguration }
            try services.deleteServiceKey(for: editingServiceID, credentials: credentials)
            key.stringValue = ""
            error.stringValue = ""
            configurationChanged()
        } catch { showFailure(error) }
        renderReadiness()
    }

    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === prompt { usesDefaultPrompt = false }
    }

    private func renderReadiness() {
        status.stringValue = switch client.readiness {
        case .disabled: "润色已关闭；原转写用于交付。"
        case .waiting(let failure): failure.localizedDescription
        case .ready: "润色配置齐全；实际 Chat 请求成功前，该角色能力尚未验证。"
        }
    }

    private func showFailure(_ failure: any Error) {
        if let failure = failure as? PolishFailure { error.stringValue = failure.localizedDescription }
        else if let failure = failure as? TranscriptionFailure {
            error.stringValue = failure == .credentialsUnavailable ? PolishFailure.credentialsUnavailable.localizedDescription : PolishFailure.invalidConfiguration.localizedDescription
        } else { error.stringValue = "设置未能保存或读取，请检查本地文件权限和可用空间。" }
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        control.widthAnchor.constraint(equalToConstant: 495).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 10
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
}

private final class PolishSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
