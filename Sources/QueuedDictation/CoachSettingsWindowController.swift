import AppKit
import DictationCore

@MainActor
final class CoachSettingsWindowController: NSWindowController, NSTextViewDelegate {
    private let scheduler: CoachWorkScheduler
    private let settings: CoachSettings
    private let services: ServiceSettings
    private let onOpenSharedServices: (() -> Void)?
    private let enabled = NSButton(checkboxWithTitle: "开启英语带教和卡片浮窗", target: nil, action: nil)
    private let servicePicker = NSPopUpButton()
    private let model = NSTextField()
    private let concurrency = NSTextField()
    private let timeout = NSTextField()
    private let corner = NSPopUpButton()
    private let prompt = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var sharedServices: [ModelService] = []
    private var usesDefaultPrompt = true

    init(scheduler: CoachWorkScheduler, settings: CoachSettings, services: ServiceSettings,
         onOpenSharedServices: (() -> Void)? = nil) {
        self.scheduler = scheduler; self.settings = settings; self.services = services
        self.onOpenSharedServices = onOpenSharedServices
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "英语文本带教"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 680)
        window.center()
        servicePicker.target = self; servicePicker.action = #selector(serviceChanged)
        model.placeholderString = "所选共享服务的文本 Chat 模型 ID"
        concurrency.placeholderString = "1–10，默认 3"
        timeout.placeholderString = "5–600 秒，默认 30"
        corner.addItems(withTitles: ["右下", "左下", "右上", "左上"])
        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true; promptScroll.borderType = .bezelBorder
        promptScroll.documentView = prompt
        prompt.isRichText = false; prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.font = .systemFont(ofSize: 13)
        prompt.isHorizontallyResizable = false; prompt.isVerticallyResizable = true
        prompt.autoresizingMask = [.width]
        prompt.textContainer?.widthTracksTextView = true
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.delegate = self
        let manage = NSButton(title: "共享服务设置…", target: self, action: #selector(openSharedServices))
        manage.isEnabled = onOpenSharedServices != nil
        let restore = NSButton(title: "恢复当前默认提示词", target: self, action: #selector(restorePrompt))
        let save = NSButton(title: "保存带教配置", target: self, action: #selector(saveSettings))
        let buttons = NSStackView(views: [save, restore, manage])
        buttons.spacing = 10
        let help = NSTextField(wrappingLabelWithString: "本段未经润色的转写和完整提示词将直发到所选共享服务的 /chat/completions。本模式没有音频，不能评流利度，也没有数字评分。带教模型一次决定是否出卡并教学；失败不会改写或阻塞主输入。")
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [enabled, row("共享服务", servicePicker), row("带教模型", model),
            row("独立并发", concurrency), row("完整截止（秒）", timeout), row("浮窗停靠", corner),
            help, NSTextField(labelWithString: "完整带教提示词"), promptScroll, buttons, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            promptScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        loadSettings()
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        loadSettings()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func textDidChange(_ notification: Notification) { usesDefaultPrompt = false }

    private func loadSettings() {
        do {
            let configuration = try settings.load()
            sharedServices = try services.load().services
            servicePicker.removeAllItems()
            let unselected = NSMenuItem(title: "尚未选择", action: nil, keyEquivalent: "")
            servicePicker.menu?.addItem(unselected)
            for service in sharedServices {
                let item = NSMenuItem(title: service.name, action: nil, keyEquivalent: "")
                item.representedObject = service.id
                servicePicker.menu?.addItem(item)
            }
            let selected = servicePicker.itemArray.first { $0.representedObject as? UUID == configuration.role?.serviceID }
            servicePicker.select(selected ?? unselected)
            model.stringValue = configuration.role?.model ?? ""
            enabled.state = configuration.enabled ? .on : .off
            concurrency.stringValue = String(configuration.concurrency)
            timeout.stringValue = String(configuration.timeout)
            corner.selectItem(at: CoachCorner.allCases.firstIndex(of: configuration.corner) ?? 0)
            prompt.string = configuration.prompt
            usesDefaultPrompt = configuration.customPrompt == nil
            describeDestination()
        } catch { showFailure(error) }
    }

    @objc private func saveSettings() {
        do {
            guard let count = Int(concurrency.stringValue), let seconds = TimeInterval(timeout.stringValue) else {
                throw CoachFailure.invalidConfiguration
            }
            let serviceID = servicePicker.selectedItem?.representedObject as? UUID
            let role = serviceID.map { ModelRoleConfiguration(serviceID: $0, model: model.stringValue) }
            guard CoachCorner.allCases.indices.contains(corner.indexOfSelectedItem) else { throw CoachFailure.invalidConfiguration }
            try settings.save(CoachConfiguration(enabled: enabled.state == .on, role: role, concurrency: count,
                timeout: seconds, customPrompt: usesDefaultPrompt ? nil : prompt.string,
                corner: CoachCorner.allCases[corner.indexOfSelectedItem]))
            try scheduler.configurationChanged()
            describeDestination()
        } catch { showFailure(error) }
    }

    @objc private func restorePrompt() {
        do {
            try settings.restoreDefaultPrompt()
            prompt.string = CoachConfiguration.defaultPrompt
            usesDefaultPrompt = true
            try scheduler.configurationChanged()
            status.textColor = .secondaryLabelColor
            status.stringValue = "已恢复当前默认提示词。"
        } catch { showFailure(error) }
    }

    @objc private func serviceChanged() { describeDestination() }
    @objc private func openSharedServices() { onOpenSharedServices?() }

    private func describeDestination() {
        status.textColor = .secondaryLabelColor
        guard let id = servicePicker.selectedItem?.representedObject as? UUID,
              let service = sharedServices.first(where: { $0.id == id }) else {
            status.stringValue = "尚未选择带教服务；已启用时会保留待发送带教，主输入继续。"
            return
        }
        status.stringValue = "数据去向：\(service.baseURL)。凭据只在实际派发时从钥匙串读取；实际文本请求成功前，带教能力尚未验证。"
    }

    private func showFailure(_ error: Error) {
        status.textColor = .systemRed
        status.stringValue = (error as? CoachFailure)?.localizedDescription ?? "带教设置未能保存，请检查本机目录与共享服务配置。"
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 12
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        return row
    }
}
