import AppKit
import DictationCore

@MainActor
final class HistoryRetentionSettingsWindowController: NSWindowController {
    private let settings: HistoryRetentionSettings
    private let configurationChanged: @MainActor () -> Void
    private let period = NSPopUpButton(frame: .zero, pullsDown: false)
    private let message = NSTextField(wrappingLabelWithString: "")

    init(settings: HistoryRetentionSettings, configurationChanged: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.configurationChanged = configurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 275),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "语音历史保留设置"
        window.isReleasedWhenClosed = false
        window.center()
        let menu = NSMenu()
        for value in HistoryRetentionPeriod.allCases {
            let item = NSMenuItem(title: value.title, action: nil, keyEquivalent: "")
            item.representedObject = value.rawValue
            menu.addItem(item)
        }
        period.menu = menu
        select(.days30)
        let title = NSTextField(labelWithString: "普通语音历史保留期")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "默认 30 天。未终结的片段和仍在处理的工作会保留。永久仍受本地空间额度限制；历史清理不删除独立的带教收藏。")
        explanation.textColor = .secondaryLabelColor
        message.textColor = .systemRed
        let save = NSButton(title: "保存保留期", target: self, action: #selector(saveSettings))
        let stack = NSStackView(views: [title, period, explanation, save, message])
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
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private var didPrepareEmbeddedView = false
    func prepareEmbeddedView() {
        guard !didPrepareEmbeddedView else { return }
        didPrepareEmbeddedView = true
        do { select(try settings.load()); message.stringValue = "" }
        catch { message.stringValue = failureMessage(error) }
    }

    func showSettings() {
        prepareEmbeddedView()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ value: HistoryRetentionPeriod) {
        period.select(period.itemArray.first { $0.representedObject as? Int == value.rawValue })
    }

    @objc private func saveSettings() {
        do {
            guard let value = period.selectedItem?.representedObject as? Int,
                  let selected = HistoryRetentionPeriod(rawValue: value) else { throw HistoryRetentionSettingsError.invalidPeriod }
            try settings.save(selected)
            message.stringValue = ""
            configurationChanged()
        } catch { message.stringValue = failureMessage(error) }
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? HistoryRetentionSettingsError)?.localizedDescription ?? "历史保留设置未能保存，请检查配置目录与可用空间。"
    }
}
