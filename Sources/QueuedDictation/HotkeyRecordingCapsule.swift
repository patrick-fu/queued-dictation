import AppKit
import DictationCore

@MainActor
final class HotkeyRecordingCapsule: NSPanel {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onToggleCoach: (() -> Void)?
    private let cancelButton = NSButton()
    private let finishButton = NSButton()
    private let waveform = CapsuleWaveformView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusRow = NSStackView()
    private var presentation = HotkeyRecordingPresentation.hidden
    private var animationTimer: Timer?
    private var dismissedResult: String?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 26
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.65).cgColor
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        contentView = backdrop

        configureButton(cancelButton, symbol: "xmark", action: #selector(cancelOrDismiss))
        configureButton(finishButton, symbol: "checkmark", action: #selector(finishRecording))
        cancelButton.setAccessibilityLabel("取消当前录音")
        finishButton.setAccessibilityLabel("结束并保存录音")
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        finishButton.layer?.backgroundColor = NSColor.systemMint.withAlphaComponent(0.18).cgColor
        finishButton.contentTintColor = .systemMint

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusIcon.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.addArrangedSubview(statusIcon)
        statusRow.addArrangedSubview(statusLabel)
        for view in [cancelButton, finishButton, waveform, statusRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(view)
        }
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 10),
            cancelButton.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 32),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),
            finishButton.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -10),
            finishButton.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            finishButton.widthAnchor.constraint(equalToConstant: 32),
            finishButton.heightAnchor.constraint(equalToConstant: 32),
            waveform.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 152),
            waveform.heightAnchor.constraint(equalToConstant: 28),
            statusRow.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            statusRow.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualToConstant: 152),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 132),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14)
        ])
        cancelButton.isEnabled = false
        finishButton.isEnabled = false
        setAccessibilityLabel("录音状态")
    }

    func renderCoach(enabled: Bool, failure: String?) {}

    func render(_ presentation: HotkeyRecordingPresentation, cancellation: HotkeyAvailability,
                inputLevel: Double = 0) {
        self.presentation = presentation
        if presentation == .hidden {
            dismissedResult = nil
            waveform.reset()
            orderOut(nil)
            return
        }
        if case .result(let message) = presentation {
            if dismissedResult == message { orderOut(nil); return }
        } else { dismissedResult = nil }

        waveform.isHidden = true
        statusRow.isHidden = false
        cancelButton.isEnabled = false
        finishButton.isEnabled = false
        cancelButton.setAccessibilityLabel("取消当前录音")
        cancelButton.toolTip = "取消当前录音"
        finishButton.toolTip = "结束并保存录音，当前不可用"
        var description: String
        switch presentation {
        case .hidden: return
        case .starting:
            setStatus("正在启动…", symbol: "mic.fill")
            cancelButton.isEnabled = onCancel != nil
            description = "正在启动录音，可点叉取消。"
        case .waitingForMicrophone:
            setStatus("等待麦克风权限", symbol: "mic.fill")
            cancelButton.isEnabled = onCancel != nil
            description = "等待麦克风授权，可点叉取消本次启动。"
        case .recording(let duration):
            let seconds = duration.isFinite ? Int(min(max(0, duration), Double(Int.max / 2))) : 0
            let elapsed = String(format: "%ld:%02ld", seconds / 60, seconds % 60)
            waveform.isHidden = false
            statusRow.isHidden = true
            waveform.setInputLevel(inputLevel, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            cancelButton.isEnabled = onCancel != nil
            finishButton.isEnabled = onFinish != nil
            finishButton.toolTip = "结束并保存当前录音"
            description = "正在录音，时长 \(elapsed)。点叉取消，点勾结束并保存。"
        case .finishing:
            setStatus("正在结束录音…", symbol: "hourglass")
            cancelButton.toolTip = "正在结束录音，暂时无法取消"
            description = "正在结束录音，等待设备停止与收尾。"
        case .result(let message):
            setStatus("录音结果", symbol: "info.circle")
            cancelButton.isEnabled = true
            cancelButton.setAccessibilityLabel("关闭录音结果")
            cancelButton.toolTip = "关闭录音结果"
            description = message + "\n可在应用中查看详情。"
        }
        if cancelButton.isEnabled, cancellation == .ready {
            switch presentation {
            case .starting, .waitingForMicrophone, .recording:
                cancelButton.toolTip = "取消当前录音，也可按 Esc"
            default: break
            }
        }
        if waveform.isHidden { waveform.reset() }
        contentView?.toolTip = description
        statusLabel.toolTip = description
        statusIcon.toolTip = description
        waveform.toolTip = description
        setAccessibilityLabel(waveform.isHidden ? statusLabel.stringValue : description)
        if !isVisible {
            placeOnCurrentScreen()
            // 只排序非激活面板，保留当前应用的键盘焦点。
            orderFrontRegardless()
        }
        refreshAnimation()
    }

    override func orderOut(_ sender: Any?) {
        stopAnimation()
        super.orderOut(sender)
    }

    override func close() {
        stopAnimation()
        super.close()
    }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.target = self
        button.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.refusesFirstResponder = true
        button.focusRingType = .none
        button.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
    }

    private func setStatus(_ title: String, symbol: String) {
        statusLabel.stringValue = title
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func refreshAnimation() {
        guard isVisible, case .recording = presentation,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopAnimation()
            return
        }
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.isVisible, case .recording = self.presentation else {
                    self.stopAnimation()
                    return
                }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.waveform.showStaticLevel()
                    self.stopAnimation()
                } else { self.waveform.advance() }
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @objc private func cancelOrDismiss() {
        switch presentation {
        case .starting, .waitingForMicrophone, .recording: onCancel?()
        case .result(let message): dismissedResult = message; orderOut(nil)
        case .hidden, .finishing: break
        }
    }

    @objc private func finishRecording() {
        guard case .recording = presentation else { return }
        onFinish?()
    }

    private func placeOnCurrentScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: bounds.midX - frame.width / 2, y: bounds.minY + 28))
    }
}

@MainActor
private final class CapsuleWaveformView: NSView {
    private var levels = Array(repeating: CGFloat.zero, count: 25)
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("实时麦克风音量")
    }

    required init?(coder: NSCoder) { nil }

    func setInputLevel(_ level: Double, reduceMotion: Bool) {
        targetLevel = level.isFinite ? CGFloat(min(1, max(0, level))) : 0
        setAccessibilityValue("输入音量 \(Int(targetLevel * 100))%")
        if reduceMotion { showStaticLevel() }
    }

    func advance() {
        smoothedLevel += (targetLevel - smoothedLevel) * (targetLevel > smoothedLevel ? 0.35 : 0.14)
        if smoothedLevel < 0.003 { smoothedLevel = 0 }
        levels.removeFirst()
        levels.append(smoothedLevel)
        needsDisplay = true
    }

    func showStaticLevel() {
        smoothedLevel = targetLevel
        levels = Array(repeating: targetLevel, count: levels.count)
        needsDisplay = true
    }

    func reset() {
        targetLevel = 0
        smoothedLevel = 0
        levels = Array(repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = bounds.width / CGFloat(levels.count)
        for (index, level) in levels.enumerated() {
            let distance = abs(CGFloat(index) - CGFloat(levels.count - 1) / 2) / CGFloat(levels.count / 2)
            let envelope = 1 - 0.45 * distance
            let height = 2 + pow(level, 0.65) * (bounds.height - 2) * envelope
            let bar = NSRect(x: step * (CGFloat(index) + 0.5) - 1.5,
                             y: bounds.midY - height / 2, width: 3, height: height)
            NSColor(calibratedRed: 0.52, green: 0.91, blue: 0.84, alpha: 0.65 + 0.3 * envelope).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
