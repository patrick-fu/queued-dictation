import AppKit
import DictationCore

private enum PolishUITheme {
    static let canvasBackground = NSColor(srgbRed: 248/255.0, green: 249/255.0, blue: 251/255.0, alpha: 1.0) // #F8F9FB
    static let cardBackground = NSColor.white // #FFFFFF
    static let primaryText = NSColor(srgbRed: 36/255.0, green: 41/255.0, blue: 54/255.0, alpha: 1.0) // #242936
    static let secondaryText = NSColor(srgbRed: 133/255.0, green: 141/255.0, blue: 156/255.0, alpha: 1.0) // #858D9C
    static let borderColor = NSColor(srgbRed: 229/255.0, green: 231/255.0, blue: 237/255.0, alpha: 1.0) // #E5E7ED
    static let accentBlue = NSColor(srgbRed: 44/255.0, green: 98/255.0, blue: 239/255.0, alpha: 1.0) // #2C62EF
    static let subtleHover = NSColor(srgbRed: 244/255.0, green: 246/255.0, blue: 249/255.0, alpha: 1.0)
    static let dangerRed = NSColor(srgbRed: 224/255.0, green: 49/255.0, blue: 49/255.0, alpha: 1.0)
    static let successGreen = NSColor(srgbRed: 40/255.0, green: 167/255.0, blue: 69/255.0, alpha: 1.0)
}

@MainActor
final class PolishSettingsWindowController: NSWindowController, NSTextViewDelegate {
    private enum ServiceSelection: Equatable { case service(UUID), none, new }
    private let settings: PolishSettings
    private let services: ServiceSettings
    private let credentials: any ServiceCredentialStoring
    private let client: PolishClient
    private let configurationChanged: @MainActor () -> Void

    private let enabled = NSSwitch()
    private let servicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let serviceName = NSTextField()
    private let baseURL = NSTextField()
    private let authentication = NSPopUpButton(frame: .zero, pullsDown: false)
    private let key = NSSecureTextField()
    private let model = NSTextField()
    private let timeout = NSTextField()
    private let prompt = NSTextView(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let statusIndicator = NSView()

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
        self.settings = settings
        self.services = services
        self.credentials = credentials
        self.client = client
        self.configurationChanged = configurationChanged

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 920),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "润色设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
        window.backgroundColor = PolishUITheme.canvasBackground
        window.center()

        // 基础控件事件与占位符
        servicePicker.target = self
        servicePicker.action = #selector(selectService)
        servicePicker.controlSize = .large
        servicePicker.font = .systemFont(ofSize: 13)

        authentication.addItems(withTitles: ["Bearer API 密钥", "无鉴权（自管本地端点）"])
        authentication.controlSize = .large
        authentication.font = .systemFont(ofSize: 13)

        configureTextField(serviceName, placeholder: "例如：OpenAI / 豆包")
        configureTextField(baseURL, placeholder: "https://api.openai.com/v1 或 http://localhost:8000/v1")
        configureTextField(key, placeholder: "新 API 密钥（空白保留原密钥；仅存钥匙串）")
        configureTextField(model, placeholder: "所选服务的 Chat 模型 ID（例如 gpt-4o）")
        configureTextField(timeout, placeholder: "5–600 秒，默认 30")

        prompt.isRichText = false
        prompt.font = .systemFont(ofSize: 13)
        prompt.textColor = PolishUITheme.primaryText
        prompt.backgroundColor = PolishUITheme.cardBackground
        prompt.drawsBackground = true
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.isVerticallyResizable = true
        prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]
        prompt.textContainer?.widthTracksTextView = true
        prompt.textContainerInset = NSSize(width: 12, height: 12)
        prompt.delegate = self

        // 根画板与主卡片容器
        let document = PolishSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = document

        // 卡片 1：顶部“润色”开关与简短说明卡
        let topCard = PolishCardView(padding: 22)
        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = PolishUITheme.accentBlue.withAlphaComponent(0.08).cgColor
        iconBox.layer?.cornerRadius = 10
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let iconImage = NSImageView()
        iconImage.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "润色")
        iconImage.contentTintColor = PolishUITheme.accentBlue
        iconImage.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconImage)
        NSLayoutConstraint.activate([
            iconImage.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconImage.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            iconImage.widthAnchor.constraint(equalToConstant: 22),
            iconImage.heightAnchor.constraint(equalToConstant: 22)
        ])

        let topTitle = NSTextField(labelWithString: "AI 文本润色")
        topTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        topTitle.textColor = PolishUITheme.primaryText

        let topBadge = PolishTagBadge(text: "Chat 整理", isAccent: true)
        let titleRow = NSStackView(views: [topTitle, topBadge])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY

        let topDesc = NSTextField(labelWithString: "整理本段转写文本，去除口语停顿并纠正语病，保留你的完整原意。")
        topDesc.font = .systemFont(ofSize: 13)
        topDesc.textColor = PolishUITheme.secondaryText
        topDesc.lineBreakMode = .byWordWrapping
        topDesc.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleRow, topDesc])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        enabled.translatesAutoresizingMaskIntoConstraints = false
        enabled.setAccessibilityLabel("启用润色")

        let topRow = NSStackView(views: [iconBox, textStack, enabled])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topCard.contentStack.addArrangedSubview(topRow)

        topRow.widthAnchor.constraint(equalTo: topCard.contentStack.widthAnchor).isActive = true
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topDesc.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        // 卡片 2：模型与服务在分组卡中明确复用共享服务
        let modelCard = PolishCardView(padding: 22)
        let modelTitle = NSTextField(labelWithString: "润色模型与共享服务")
        modelTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        modelTitle.textColor = PolishUITheme.primaryText

        let modelBadge = PolishTagBadge(text: "全局共享")
        let modelTitleRow = NSStackView(views: [modelTitle, modelBadge])
        modelTitleRow.orientation = .horizontal
        modelTitleRow.spacing = 8
        modelTitleRow.alignment = .centerY

        let modelDesc = NSTextField(labelWithString: "多个功能角色可复用同一共享服务；润色模型仅在当前角色生效，超时后自动终止本次请求。")
        modelDesc.font = .systemFont(ofSize: 12)
        modelDesc.textColor = PolishUITheme.secondaryText
        modelDesc.lineBreakMode = .byWordWrapping

        let modelHeader = NSStackView(views: [modelTitleRow, modelDesc])
        modelHeader.orientation = .vertical
        modelHeader.alignment = .leading
        modelHeader.spacing = 4
        modelCard.contentStack.addArrangedSubview(modelHeader)
        modelHeader.widthAnchor.constraint(equalTo: modelCard.contentStack.widthAnchor).isActive = true
        modelDesc.widthAnchor.constraint(equalTo: modelHeader.widthAnchor).isActive = true

        let colService = makeFieldColumn(title: "共享服务", control: servicePicker, caption: "选择已有服务或新增端点")
        let colModel = makeFieldColumn(title: "润色模型 ID", control: PolishInputWrapper(control: model), caption: "用于润色的 Chat 模型标识")
        let colTimeout = makeFieldColumn(title: "整体截止（秒）", control: PolishInputWrapper(control: timeout), caption: "5–600 秒，默认 30")

        let modelGrid = NSStackView(views: [colService, colModel, colTimeout])
        modelGrid.orientation = .horizontal
        modelGrid.distribution = .fillEqually
        modelGrid.spacing = 16
        modelGrid.translatesAutoresizingMaskIntoConstraints = false
        modelCard.contentStack.addArrangedSubview(modelGrid)
        modelGrid.widthAnchor.constraint(equalTo: modelCard.contentStack.widthAnchor).isActive = true

        // 卡片 3：服务端点与鉴权单独卡
        let endpointCard = PolishCardView(padding: 22)
        let endpointTitle = NSTextField(labelWithString: "服务端点与凭据配置")
        endpointTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        endpointTitle.textColor = PolishUITheme.primaryText

        let endpointDesc = NSTextField(labelWithString: "配置所选共享服务的通信协议与端点；API 密钥仅存储在系统钥匙串中，不会明文导出。")
        endpointDesc.font = .systemFont(ofSize: 12)
        endpointDesc.textColor = PolishUITheme.secondaryText
        endpointDesc.lineBreakMode = .byWordWrapping

        let endpointHeader = NSStackView(views: [endpointTitle, endpointDesc])
        endpointHeader.orientation = .vertical
        endpointHeader.alignment = .leading
        endpointHeader.spacing = 4
        endpointCard.contentStack.addArrangedSubview(endpointHeader)
        endpointHeader.widthAnchor.constraint(equalTo: endpointCard.contentStack.widthAnchor).isActive = true
        endpointDesc.widthAnchor.constraint(equalTo: endpointHeader.widthAnchor).isActive = true

        let colName = makeFieldColumn(title: "服务名称", control: PolishInputWrapper(control: serviceName), caption: "在共享服务列表中显示的名称")
        let colURL = makeFieldColumn(title: "Base URL", control: PolishInputWrapper(control: baseURL), caption: "兼容 /chat/completions 的根地址")
        let row1 = NSStackView(views: [colName, colURL])
        row1.orientation = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 16
        row1.translatesAutoresizingMaskIntoConstraints = false
        endpointCard.contentStack.addArrangedSubview(row1)
        row1.widthAnchor.constraint(equalTo: endpointCard.contentStack.widthAnchor).isActive = true

        let colAuth = makeFieldColumn(title: "服务鉴权", control: authentication, caption: "Bearer Token 或本地免鉴权端点")
        let colKey = makeFieldColumn(title: "API 密钥", control: PolishInputWrapper(control: key), caption: "空白保留原密钥；仅存钥匙串")
        let row2 = NSStackView(views: [colAuth, colKey])
        row2.orientation = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 16
        row2.translatesAutoresizingMaskIntoConstraints = false
        endpointCard.contentStack.addArrangedSubview(row2)
        row2.widthAnchor.constraint(equalTo: endpointCard.contentStack.widthAnchor).isActive = true

        let saveServiceBtn = PolishSecondaryButton(title: "保存共享服务", target: self, action: #selector(saveSharedService))
        let deleteKeyBtn = PolishSecondaryButton(title: "删除所选服务密钥", target: self, action: #selector(deleteServiceKey), isDestructive: true)
        let serviceHint = NSTextField(labelWithString: "修改端点或密钥将同步影响使用此服务的全部角色")
        serviceHint.font = .systemFont(ofSize: 12)
        serviceHint.textColor = PolishUITheme.secondaryText

        let serviceButtonRow = NSStackView(views: [saveServiceBtn, deleteKeyBtn, serviceHint])
        serviceButtonRow.orientation = .horizontal
        serviceButtonRow.spacing = 12
        serviceButtonRow.alignment = .centerY
        serviceButtonRow.translatesAutoresizingMaskIntoConstraints = false
        endpointCard.contentStack.addArrangedSubview(serviceButtonRow)
        serviceButtonRow.widthAnchor.constraint(equalTo: endpointCard.contentStack.widthAnchor).isActive = true

        // 卡片 4：完整提示词编辑器独立大卡，高度 200 pt
        let promptCard = PolishCardView(padding: 22)
        let promptTitle = NSTextField(labelWithString: "完整润色提示词")
        promptTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        promptTitle.textColor = PolishUITheme.primaryText

        let promptBadge = PolishTagBadge(text: "System Prompt")
        let promptTitleRow = NSStackView(views: [promptTitle, promptBadge])
        promptTitleRow.orientation = .horizontal
        promptTitleRow.spacing = 8
        promptTitleRow.alignment = .centerY

        let promptDesc = NSTextField(labelWithString: "定义模型的润色原则与输出要求。润色时会将本段原始转写与此提示词直发到所选端点。")
        promptDesc.font = .systemFont(ofSize: 12)
        promptDesc.textColor = PolishUITheme.secondaryText
        promptDesc.lineBreakMode = .byWordWrapping

        let promptHeader = NSStackView(views: [promptTitleRow, promptDesc])
        promptHeader.orientation = .vertical
        promptHeader.alignment = .leading
        promptHeader.spacing = 4
        promptCard.contentStack.addArrangedSubview(promptHeader)
        promptHeader.widthAnchor.constraint(equalTo: promptCard.contentStack.widthAnchor).isActive = true
        promptDesc.widthAnchor.constraint(equalTo: promptHeader.widthAnchor).isActive = true

        let editor = NSScrollView()
        editor.hasVerticalScroller = true
        editor.drawsBackground = true
        editor.backgroundColor = PolishUITheme.cardBackground
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 8
        editor.layer?.borderColor = PolishUITheme.borderColor.cgColor
        editor.layer?.borderWidth = 1
        editor.documentView = prompt
        editor.translatesAutoresizingMaskIntoConstraints = false
        promptCard.contentStack.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalTo: promptCard.contentStack.widthAnchor).isActive = true
        editor.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let restoreBtn = PolishSecondaryButton(title: "恢复当前默认提示词", target: self, action: #selector(restorePrompt))
        let savePolishBtn = PolishPrimaryButton(title: "保存润色设置", target: self, action: #selector(savePolishSettings))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let promptButtonRow = NSStackView(views: [restoreBtn, spacer, savePolishBtn])
        promptButtonRow.orientation = .horizontal
        promptButtonRow.alignment = .centerY
        promptButtonRow.spacing = 12
        promptButtonRow.translatesAutoresizingMaskIntoConstraints = false
        promptCard.contentStack.addArrangedSubview(promptButtonRow)
        promptButtonRow.widthAnchor.constraint(equalTo: promptCard.contentStack.widthAnchor).isActive = true

        // 底部：运行状态与隐私/技术说明（不占首屏）
        let footerCard = PolishCardView(padding: 18)
        statusIndicator.wantsLayer = true
        statusIndicator.layer?.cornerRadius = 4
        statusIndicator.layer?.backgroundColor = PolishUITheme.secondaryText.cgColor
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusIndicator.heightAnchor.constraint(equalToConstant: 8).isActive = true

        status.font = .systemFont(ofSize: 12)
        status.textColor = PolishUITheme.primaryText
        status.lineBreakMode = .byWordWrapping

        let statusRow = NSStackView(views: [statusIndicator, status])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        footerCard.contentStack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: footerCard.contentStack.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: statusRow.widthAnchor, constant: -16).isActive = true

        error.font = .systemFont(ofSize: 12, weight: .medium)
        error.textColor = PolishUITheme.dangerRed
        error.lineBreakMode = .byWordWrapping
        footerCard.contentStack.addArrangedSubview(error)
        error.widthAnchor.constraint(equalTo: footerCard.contentStack.widthAnchor).isActive = true

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = PolishUITheme.borderColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        footerCard.contentStack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: footerCard.contentStack.widthAnchor).isActive = true

        let privacy = NSTextField(wrappingLabelWithString: "技术说明与隐私保证：仅将本段原始转写和完整提示词直发到所选 Base URL 的 /chat/completions。配置齐全后仍需实际请求验证该角色能力。润色与转写共享请求并发。")
        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = PolishUITheme.secondaryText
        privacy.lineBreakMode = .byWordWrapping
        footerCard.contentStack.addArrangedSubview(privacy)
        privacy.widthAnchor.constraint(equalTo: footerCard.contentStack.widthAnchor).isActive = true

        // 组合并约束卡片垂直堆叠
        let masterStack = NSStackView(views: [topCard, modelCard, endpointCard, promptCard, footerCard])
        masterStack.orientation = .vertical
        masterStack.alignment = .leading
        masterStack.spacing = 20
        masterStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(masterStack)

        NSLayoutConstraint.activate([
            masterStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            masterStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            masterStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            masterStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            topCard.widthAnchor.constraint(equalTo: masterStack.widthAnchor),
            modelCard.widthAnchor.constraint(equalTo: masterStack.widthAnchor),
            endpointCard.widthAnchor.constraint(equalTo: masterStack.widthAnchor),
            promptCard.widthAnchor.constraint(equalTo: masterStack.widthAnchor),
            footerCard.widthAnchor.constraint(equalTo: masterStack.widthAnchor)
        ])
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
        switch client.readiness {
        case .disabled:
            status.stringValue = "润色已关闭；原转写直接用于交付。"
            statusIndicator.layer?.backgroundColor = PolishUITheme.secondaryText.cgColor
        case .waiting(let failure):
            status.stringValue = failure.localizedDescription
            statusIndicator.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .ready:
            status.stringValue = "润色配置齐全；实际 Chat 请求成功前，该角色能力尚未验证。"
            statusIndicator.layer?.backgroundColor = PolishUITheme.successGreen.cgColor
        }
    }

    private func showFailure(_ failure: any Error) {
        if let failure = failure as? PolishFailure { error.stringValue = failure.localizedDescription }
        else if let failure = failure as? TranscriptionFailure {
            error.stringValue = failure == .credentialsUnavailable ? PolishFailure.credentialsUnavailable.localizedDescription : PolishFailure.invalidConfiguration.localizedDescription
        } else { error.stringValue = "设置未能保存或读取，请检查本地文件权限和可用空间。" }
        statusIndicator.layer?.backgroundColor = PolishUITheme.dangerRed.cgColor
    }

    private func configureTextField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.textColor = PolishUITheme.primaryText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
    }

    private func makeFieldColumn(title: String, control: NSView, caption: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = PolishUITheme.primaryText

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = PolishUITheme.secondaryText
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.maximumNumberOfLines = 2

        let col = NSStackView(views: [titleLabel, control, captionLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false

        control.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        captionLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }
}

// MARK: - AppKit 自定义生产视觉辅助组件

private final class PolishSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PolishCardView: NSView {
    let contentStack = NSStackView()

    init(padding: CGFloat = 22) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PolishUITheme.cardBackground.cgColor
        layer?.cornerRadius = 14
        layer?.borderColor = PolishUITheme.borderColor.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = PolishUITheme.cardBackground.cgColor
        layer?.borderColor = PolishUITheme.borderColor.cgColor
    }
}

private final class PolishTagBadge: NSView {
    init(text: String, isAccent: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isAccent
            ? PolishUITheme.accentBlue.withAlphaComponent(0.1).cgColor
            : PolishUITheme.subtleHover.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = isAccent ? PolishUITheme.accentBlue : PolishUITheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class PolishInputWrapper: NSView {
    private let control: NSControl

    init(control: NSControl) {
        self.control = control
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PolishUITheme.cardBackground.cgColor
        layer?.borderColor = PolishUITheme.borderColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(control)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = PolishUITheme.cardBackground.cgColor
        layer?.borderColor = PolishUITheme.borderColor.cgColor
    }
}

private final class PolishPrimaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.backgroundColor = PolishUITheme.accentBlue.cgColor
        self.layer?.cornerRadius = 8

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .paragraphStyle: style
            ]
        )
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag ? PolishUITheme.accentBlue.withAlphaComponent(0.85).cgColor : PolishUITheme.accentBlue.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = PolishUITheme.accentBlue.cgColor
    }
}

private final class PolishSecondaryButton: NSButton {
    private let isDestructive: Bool

    init(title: String, target: AnyObject?, action: Selector?, isDestructive: Bool = false) {
        self.isDestructive = isDestructive
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.backgroundColor = PolishUITheme.cardBackground.cgColor
        self.layer?.borderColor = (isDestructive ? PolishUITheme.dangerRed.withAlphaComponent(0.4) : PolishUITheme.borderColor).cgColor
        self.layer?.borderWidth = 1
        self.layer?.cornerRadius = 8

        let textColor = isDestructive ? PolishUITheme.dangerRed : PolishUITheme.primaryText
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .paragraphStyle: style
            ]
        )
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag ? PolishUITheme.subtleHover.cgColor : PolishUITheme.cardBackground.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = PolishUITheme.cardBackground.cgColor
        layer?.borderColor = (isDestructive ? PolishUITheme.dangerRed.withAlphaComponent(0.4) : PolishUITheme.borderColor).cgColor
    }
}
