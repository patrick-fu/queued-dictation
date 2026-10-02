import AppKit
import DictationCore

@MainActor
final class HotkeyRecordingCapsule: NSPanel {
    var onCancel: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "取消", target: nil, action: nil)
    private var allowsCancellation = false
    private var dismissedResult: String?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 18
        backdrop.layer?.masksToBounds = true
        contentView = backdrop
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, messageLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.bezelStyle = .rounded
        let row = NSStackView(views: [text, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            messageLabel.widthAnchor.constraint(equalToConstant: 310),
            detailLabel.widthAnchor.constraint(equalTo: messageLabel.widthAnchor)
        ])
        setAccessibilityLabel("录音状态")
    }

    func render(_ presentation: HotkeyRecordingPresentation, cancellation: HotkeyAvailability) {
        if presentation == .hidden { orderOut(nil); return }
        if case .result(let message) = presentation {
            if dismissedResult == message { orderOut(nil); return }
        } else { dismissedResult = nil }
        var height: CGFloat = 94
        titleLabel.stringValue = "Queued Dictation"
        allowsCancellation = true
        detailLabel.stringValue = cancellation == .ready ? "Esc 仅取消当前录音" : "可点取消，仅影响当前录音"
        actionButton.title = "取消"
        switch presentation {
        case .hidden: return
        case .starting: messageLabel.stringValue = "正在启动采集…"
        case .waitingForMicrophone: messageLabel.stringValue = "等待麦克风授权"
        case .recording(let duration):
            let seconds = max(0, Int(duration))
            messageLabel.stringValue = String(format: "正在录音 · %d:%02d", seconds / 60, seconds % 60)
        case .finishing:
            messageLabel.stringValue = "正在结束录音…"
            detailLabel.stringValue = "等待设备停止与安全收尾"
        case .result(let message):
            allowsCancellation = false
            titleLabel.stringValue = "录音结果"
            messageLabel.stringValue = message
            detailLabel.stringValue = "可从 App 查看历史或更改设置"
            actionButton.title = "关闭"
            height = 142
        }
        setContentSize(NSSize(width: 420, height: height))
        if !isVisible { placeOnCurrentScreen() }
        // 状态自动出现只排序窗口；非激活面板且拒绝成为 key/main window。
        orderFrontRegardless()
    }

    @objc private func performAction() {
        if allowsCancellation { onCancel?() }
        else { dismissedResult = messageLabel.stringValue; orderOut(nil) }
    }

    private func placeOnCurrentScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: bounds.midX - frame.width / 2, y: bounds.minY + 28))
    }
}
