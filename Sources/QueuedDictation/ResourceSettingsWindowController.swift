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

    init(settings: ResourceSettings, runtimeStatus: @escaping @MainActor () -> String = { "" }, configurationChanged: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.runtimeStatus = runtimeStatus
        self.configurationChanged = configurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "录音额度与自动发送时间窗"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 780)
        window.center()
        let identifiers = ["maximumPendingSegments", "maximumPendingDuration", "maximumPendingAudioBytes",
                           "maximumRecordingDuration", "maximumLocalBytes", "automaticSendingWindow"]
        for (field, identifier) in zip(fields, identifiers) {
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        runtime.textColor = .secondaryLabelColor
        runtime.identifier = NSUserInterfaceItemIdentifier("runtime-resource-usage")
        current.textColor = .secondaryLabelColor
        current.identifier = NSUserInterfaceItemIdentifier("current-resource-settings")
        error.textColor = .systemRed
        error.identifier = NSUserInterfaceItemIdentifier("resource-settings-error")
        let title = NSTextField(labelWithString: "限制录音积压与本地占用")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "多个录音额度由最先到达的一项限制。调低额度保留已有数据，限制新录音和后续派发。超期未发工作须主动恢复；带教暂停不阻塞主输入。请求并发和整体截止在相应处理设置中配置。")
        help.textColor = .secondaryLabelColor
        let units = NSTextField(wrappingLabelWithString: "时长可输入小数。空间额度使用 MiB / GiB，可输入小数，但必须对应完整字节。自动发送时间窗从录音实际结束或主动恢复计算，恰好到达边界仍有效。")
        units.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存", target: self, action: #selector(saveConfiguration))
        save.identifier = NSUserInterfaceItemIdentifier("save-resource-settings")
        save.keyEquivalent = "\r"
        let reload = NSButton(title: "重新读取", target: self, action: #selector(reloadConfiguration))
        let buttons = NSStackView(views: [reload, save])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, help,
            row("主积压片段数", pendingSegments, "段，整数 1–100"),
            row("主积压累计时长", pendingDuration, "分钟，1–120"),
            row("主积压音频额度", pendingAudio, "MiB，64–2048"),
            row("单段录音时长", recordingDuration, "分钟，1–60"),
            row("全本地数据额度", localBytes, "GiB，1–100"),
            row("自动发送时间窗", sendingWindow, "小时，1–168"),
            units, current, runtime, error, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22)
        ])
        for view in stack.arrangedSubviews where view !== title && view !== buttons {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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

    private func row(_ title: String, _ field: NSTextField, _ unit: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        let range = NSTextField(labelWithString: unit)
        range.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        field.setAccessibilityLabel("\(title)，\(unit)")
        let row = NSStackView(views: [label, field, range])
        row.spacing = 12
        row.alignment = .centerY
        return row
    }
}
