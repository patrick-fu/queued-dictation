import AppKit
import DictationCore

@MainActor
final class DeliverySettingsWindowController: NSWindowController {
    private let settings: DeliverySettings
    private let delivery: CrossAppTextDelivery
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: DeliverySettings, delivery: CrossAppTextDelivery) {
        self.settings = settings
        self.delivery = delivery
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 430),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "文本上屏"
        window.isReleasedWhenClosed = false
        window.center()
        let title = NSTextField(labelWithString: "选择每段语音的上屏位置")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        mode.addItems(withTitles: ["录音时输入框（默认）", "交付时当前光标"])
        mode.target = self
        mode.action = #selector(saveSelectedMode)
        errorLabel.textColor = .systemRed
        let help = NSTextField(wrappingLabelWithString:
            "保存后只影响新开始的片段。已有片段仍沿用开始录音时的模式。密码、安全输入或无法可靠核验的控件均待手动上屏；复制不会放行队列，写回不确定时请检查目标并确认。")
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, mode, descriptionLabel, statusLabel, help, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        for label in [descriptionLabel, statusLabel, help, errorLabel] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        loadConfiguration()
        render()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        render()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func render() {
        mode.selectItem(at: delivery.configuration.mode == .recordingTarget ? 0 : 1)
        descriptionLabel.stringValue = delivery.configuration.mode == .recordingTarget
            ? "开始录音时记录输入框与光标。交付前如果曾失焦、关闭、手打、移动光标或无法确认未变，保留结果待手动上屏。"
            : "只在本段真正轮到交付时，向当时聚焦的可写输入框插入。此模式不保护开始录音时的位置；没有可靠可写目标仍待手动上屏。"
        statusLabel.stringValue = delivery.automaticDeliveryEnabled
            ? (delivery.accessibilityAuthorized ? "辅助功能已获准；能否自动上屏取决于目标控件的实际核验。" : "辅助功能未获准；结果可在队列中手动取用。")
            : "上屏设置未就绪，自动上屏暂停；重新选择并保存后生效。"
    }

    private func loadConfiguration() {
        do {
            delivery.updateConfiguration(try settings.load())
            delivery.automaticDeliveryEnabled = true
            errorLabel.stringValue = ""
        } catch {
            delivery.automaticDeliveryEnabled = false
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func saveSelectedMode() {
        let configuration = DeliveryConfiguration(mode: mode.indexOfSelectedItem == 0 ? .recordingTarget : .currentCursor)
        do {
            try settings.save(configuration)
            delivery.updateConfiguration(configuration)
            delivery.automaticDeliveryEnabled = true
            errorLabel.stringValue = ""
        } catch { errorLabel.stringValue = error.localizedDescription }
        render()
    }
}
