import AppKit
import DictationCore

@MainActor
final class ResourceSettingsWindowController: NSWindowController {
    private let settings: ResourceSettings
    private let runtimeStatus: @MainActor () -> String
    private let runtime = NSTextField(wrappingLabelWithString: "")
    private let configurationChanged: @MainActor () -> Void
    private let pendingSegments = NSTextField()
    private let pendingDuration = NSTextField()
    private let pendingAudio = NSTextField()
    private let recordingDuration = NSTextField()
    private let localBytes = NSTextField()
    private let sendingWindow = NSTextField()
    private let current = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private var loadedConfiguration: ResourceConfiguration?
    private var displayedValues = Array(repeating: "", count: 6)
    private var fields: [NSTextField] { [pendingSegments, pendingDuration, pendingAudio, recordingDuration, localBytes, sendingWindow] }

    private var saveButton: ResourcePrimaryButton!
    private var reloadButton: ResourceSecondaryButton!

    init(settings: ResourceSettings, runtimeStatus: @escaping @MainActor () -> String = { "" }, configurationChanged: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.runtimeStatus = runtimeStatus
        self.configurationChanged = configurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "录音额度与自动发送时间窗"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 600)
        window.center()

        let identifiers = ["maximumPendingSegments", "maximumPendingDuration", "maximumPendingAudioBytes",
                           "maximumRecordingDuration", "maximumLocalBytes", "automaticSendingWindow"]
        for (field, identifier) in zip(fields, identifiers) {
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.textColor = ResourcePalette.textPrimary
            field.wantsLayer = true
            field.layer?.cornerRadius = 8
            field.layer?.borderWidth = 1
            field.layer?.borderColor = ResourcePalette.border.cgColor
            field.layer?.backgroundColor = ResourcePalette.cardBackground.cgColor
            field.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }

        runtime.textColor = ResourcePalette.textSecondary
        runtime.font = .systemFont(ofSize: 12)
        runtime.identifier = NSUserInterfaceItemIdentifier("runtime-resource-usage")

        current.textColor = ResourcePalette.textSecondary
        current.font = .systemFont(ofSize: 12)
        current.identifier = NSUserInterfaceItemIdentifier("current-resource-settings")

        error.textColor = ResourcePalette.errorRed
        error.font = .systemFont(ofSize: 12)
        error.identifier = NSUserInterfaceItemIdentifier("resource-settings-error")

        setupLayout(in: window)
        reloadConfiguration()
    }

    required init?(coder: NSCoder) { nil }

    func renderRuntimeStatus() { runtime.stringValue = runtimeStatus() }

    func present() {
        renderRuntimeStatus()
        if fields.map(\.stringValue) == displayedValues { reloadConfiguration() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func prepareEmbeddedView() {
        renderRuntimeStatus()
        if fields.map(\.stringValue) == displayedValues { reloadConfiguration() }
    }

    @objc private func reloadConfiguration() {
        do {
            show(try settings.load())
            error.stringValue = ""
        } catch {
            loadedConfiguration = nil
            displayedValues = Array(repeating: "", count: 6)
            for field in fields { field.stringValue = "" }
            current.stringValue = "尚未读取到有效配置；请填写六项后保存以修复。"
            self.error.stringValue = error.localizedDescription
        }
    }

    @objc private func saveConfiguration() {
        do {
            guard let segments = Int(pendingSegments.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ResourceSettingsError.invalidPendingSegments
            }
            let configuration = try ResourceConfiguration(
                maximumPendingSegments: segments,
                maximumPendingDuration: seconds(pendingDuration, unit: 60, original: loadedConfiguration?.maximumPendingDuration,
                                                index: 1, failure: .invalidPendingDuration),
                maximumPendingAudioBytes: bytes(pendingAudio, unit: 1_048_576, original: loadedConfiguration?.maximumPendingAudioBytes,
                                                index: 2, failure: .invalidPendingAudioBytes),
                maximumRecordingDuration: seconds(recordingDuration, unit: 60, original: loadedConfiguration?.maximumRecordingDuration,
                                                  index: 3, failure: .invalidRecordingDuration),
                maximumLocalBytes: bytes(localBytes, unit: 1_073_741_824, original: loadedConfiguration?.maximumLocalBytes,
                                         index: 4, failure: .invalidLocalBytes),
                automaticSendingWindow: seconds(sendingWindow, unit: 3_600, original: loadedConfiguration?.automaticSendingWindow,
                                                index: 5, failure: .invalidAutomaticSendingWindow)
            )
            try settings.save(configuration)
            show(configuration)
            error.stringValue = ""
            configurationChanged()
            renderRuntimeStatus()
        } catch { self.error.stringValue = error.localizedDescription }
    }

    private func show(_ configuration: ResourceConfiguration) {
        loadedConfiguration = configuration
        displayedValues = [String(configuration.maximumPendingSegments), String(configuration.maximumPendingDuration / 60),
                           units(configuration.maximumPendingAudioBytes, divisor: 1_048_576), String(configuration.maximumRecordingDuration / 60),
                           units(configuration.maximumLocalBytes, divisor: 1_073_741_824), String(configuration.automaticSendingWindow / 3_600)]
        for (field, value) in zip(fields, displayedValues) { field.stringValue = value }
        current.stringValue = "当前有效值：主积压 \(displayedValues[0]) 段 / \(displayedValues[1]) 分钟 / \(displayedValues[2]) MiB；单段 \(displayedValues[3]) 分钟；本地 \(displayedValues[4]) GiB；自动发送 \(displayedValues[5]) 小时。"
    }

    private func seconds(_ field: NSTextField, unit: Double, original: TimeInterval?, index: Int,
                         failure: ResourceSettingsError) throws -> TimeInterval {
        // 单位回显经过除法；未编辑字段保留原秒数，避免再次换算改变有效值。
        if let original, field.stringValue == displayedValues[index] { return original }
        guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (value * unit).isFinite else { throw failure }
        return value * unit
    }

    private func bytes(_ field: NSTextField, unit: UInt64, original: UInt64?, index: Int,
                       failure: ResourceSettingsError) throws -> UInt64 {
        if let original, field.stringValue == displayedValues[index] { return original }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { throw failure }
        var integer = String(parts[0].drop(while: { $0 == "0" }))
        if integer.isEmpty { integer = "0" }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" { fraction.removeLast() }
        // Decimal 的精度必须足以容纳输入，不能把多出的非零位静默舍掉。
        guard integer.count + fraction.count <= 38,
              var amount = Decimal(string: integer + (fraction.isEmpty ? "" : "." + fraction),
                                   locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { throw failure }
        var multiplier = Decimal(unit)
        var product = Decimal()
        guard NSDecimalMultiply(&product, &amount, &multiplier, .plain) == .noError else { throw failure }
        var integral = Decimal()
        NSDecimalRound(&integral, &product, 0, .plain)
        guard integral == product, let result = UInt64(NSDecimalNumber(decimal: product).stringValue) else { throw failure }
        return result
    }

    private func units(_ bytes: UInt64, divisor: UInt64) -> String {
        NSDecimalNumber(decimal: Decimal(bytes) / Decimal(divisor)).stringValue
    }

    private func row(_ title: String, _ field: NSTextField, _ unit: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = ResourcePalette.textPrimary
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let range = NSTextField(labelWithString: unit)
        range.font = .systemFont(ofSize: 12)
        range.textColor = ResourcePalette.textSecondary
        range.widthAnchor.constraint(equalToConstant: 120).isActive = true

        field.setAccessibilityLabel("\(title)，\(unit)")
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true

        let row = NSStackView(views: [label, field, range])
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY
        return row
    }

    private func setupLayout(in window: NSWindow) {
        let root = ResourceContentView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let titleLabel = NSTextField(labelWithString: "限制录音积压与本地占用")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = ResourcePalette.textPrimary
        headerStack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "精细化配置积压队列上限、单段时长、存储容量与超时自动发送时间窗。")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = ResourcePalette.textSecondary
        headerStack.addArrangedSubview(subtitleLabel)

        let queueCard = ResourceCardView(
            title: "录音与积压",
            subtitle: "限制未完成片段的堆积数量、总时长与单段录音长度。",
            contentViews: [
                row("主积压片段数", pendingSegments, "段 · 1–100"),
                row("主积压累计时长", pendingDuration, "分钟 · 1–120"),
                row("主积压音频额度", pendingAudio, "MiB · 64–2048"),
                row("单段录音时长", recordingDuration, "分钟 · 1–60")
            ]
        )

        let storageCard = ResourceCardView(
            title: "本地存储",
            subtitle: "限制音频原始文件、中间结果与历史记录在磁盘的最高占用。",
            contentViews: [
                row("全本地数据额度", localBytes, "GiB · 1–100")
            ]
        )

        let windowCard = ResourceCardView(
            title: "发送时间窗",
            subtitle: "录音结束后自动向服务端发送的有效时间窗口，超时需主动恢复。",
            contentViews: [
                row("自动发送时间窗", sendingWindow, "小时 · 1–168")
            ]
        )

        let help = NSTextField(wrappingLabelWithString:
            "多个录音额度由最先到达的一项限制。调低额度保留已有数据，限制新录音和后续派发。超期未发工作须主动恢复；带教暂停不阻塞主输入。时长可输入小数。空间额度使用 MiB / GiB，可输入小数，但必须对应完整字节。自动发送时间窗从录音实际结束或主动恢复计算，恰好到达边界仍有效。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = ResourcePalette.textSecondary

        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.distribution = .fill
        footerStack.spacing = 14

        let statusBox = NSStackView(views: [current, runtime, error])
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.spacing = 4

        reloadButton = ResourceSecondaryButton(title: "重新读取", target: self, action: #selector(reloadConfiguration))
        saveButton = ResourcePrimaryButton(title: "保存", target: self, action: #selector(saveConfiguration))
        saveButton.identifier = NSUserInterfaceItemIdentifier("save-resource-settings")
        saveButton.keyEquivalent = "\r"

        let buttonsStack = NSStackView(views: [reloadButton, saveButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 12

        footerStack.addArrangedSubview(statusBox)
        footerStack.addArrangedSubview(buttonsStack)
        statusBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonsStack.setContentHuggingPriority(.required, for: .horizontal)

        let mainStack = NSStackView(views: [headerStack, queueCard, storageCard, windowCard, help, footerStack])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            headerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            queueCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            storageCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            windowCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            help.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])
    }
}

// MARK: - Private Styling and Helper Components

private enum ResourcePalette {
    static let canvasBackground = NSColor(srgbRed: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1.0)
    static let cardBackground = NSColor.white
    static let border = NSColor(srgbRed: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0)
    static let textPrimary = NSColor(srgbRed: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)
    static let textSecondary = NSColor(srgbRed: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0)
    static let primaryBlue = NSColor(srgbRed: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 1.0)
    static let primaryBlueHover = NSColor(srgbRed: 0x1E/255.0, green: 0x50/255.0, blue: 0xD8/255.0, alpha: 1.0)
    static let errorRed = NSColor(srgbRed: 0xEF/255.0, green: 0x44/255.0, blue: 0x44/255.0, alpha: 1.0)
}

private final class ResourceContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ResourceCardView: NSView {
    init(title: String, subtitle: String? = nil, contentViews: [NSView] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ResourcePalette.cardBackground.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = ResourcePalette.border.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let innerStack = NSStackView()
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 14
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(innerStack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = ResourcePalette.textPrimary
        innerStack.addArrangedSubview(titleLabel)

        if let subtitle = subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = ResourcePalette.textSecondary
            innerStack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
            innerStack.setCustomSpacing(14, after: subtitleLabel)
        } else {
            innerStack.setCustomSpacing(14, after: titleLabel)
        }

        for view in contentViews {
            innerStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            innerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            innerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            innerStack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            innerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class ResourcePrimaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        layer?.backgroundColor = ResourcePalette.primaryBlue.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .paragraphStyle: paragraph
            ]
        )
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag ? ResourcePalette.primaryBlueHover.cgColor : ResourcePalette.primaryBlue.cgColor
    }
}

private final class ResourceSecondaryButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = ResourcePalette.border.cgColor
        layer?.backgroundColor = ResourcePalette.cardBackground.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: ResourcePalette.textPrimary,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .paragraphStyle: paragraph
            ]
        )
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag
            ? NSColor(srgbRed: 0xF3/255.0, green: 0xF4/255.0, blue: 0xF6/255.0, alpha: 1.0).cgColor
            : ResourcePalette.cardBackground.cgColor
    }
}
