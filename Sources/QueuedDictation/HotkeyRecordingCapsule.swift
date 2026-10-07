import AppKit
import DictationCore

@MainActor
final class HotkeyRecordingCapsule: NSPanel {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onToggleCoach: (() -> Void)?
    private let cancelButton = CapsuleIconButton(style: .cancel, symbol: "xmark")
    private let finishButton = CapsuleIconButton(style: .confirm, symbol: "checkmark")
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 196, height: 38),
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

        let backdrop = CapsuleBackgroundView()
        contentView = backdrop

        cancelButton.target = self
        cancelButton.action = #selector(cancelOrDismiss)
        finishButton.target = self
        finishButton.action = #selector(finishRecording)
        cancelButton.setAccessibilityLabel("取消当前录音")
        finishButton.setAccessibilityLabel("结束并保存录音")

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusIcon.contentTintColor = NSColor(srgbRed: 84 / 255.0, green: 138 / 255.0, blue: 255 / 255.0, alpha: 0.90)
        statusIcon.imageScaling = .scaleProportionallyDown

        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 4
        statusRow.addArrangedSubview(statusIcon)
        statusRow.addArrangedSubview(statusLabel)

        for view in [cancelButton, finishButton, waveform, statusRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(view)
        }

        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 6),
            cancelButton.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 26),
            cancelButton.heightAnchor.constraint(equalToConstant: 26),

            finishButton.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -6),
            finishButton.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            finishButton.widthAnchor.constraint(equalToConstant: 26),
            finishButton.heightAnchor.constraint(equalToConstant: 26),

            waveform.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 116),
            waveform.heightAnchor.constraint(equalToConstant: 20),

            statusRow.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            statusRow.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualToConstant: 116),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
            statusIcon.widthAnchor.constraint(equalToConstant: 12),
            statusIcon.heightAnchor.constraint(equalToConstant: 12)
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

    private func setStatus(_ title: String, symbol: String) {
        statusLabel.stringValue = title
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
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
private final class CapsuleBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }
}

@MainActor
private final class CapsuleIconButton: NSButton {
    enum Style {
        case cancel
        case confirm
    }

    private let style: Style
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(style: Style, symbol: String) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        self.title = ""
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.refusesFirstResponder = true
        self.focusRingType = .none
        self.wantsLayer = true
        self.layer?.cornerRadius = 13
        self.layer?.masksToBounds = true

        let pointSize: CGFloat = style == .confirm ? 11.0 : 10.0
        let weight: NSFont.Weight = style == .confirm ? .bold : .semibold
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))

        updateVisuals()
    }

    required init?(coder: NSCoder) { nil }

    // AppKit's bezel alignment insets otherwise make a square constraint taller than it is wide.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override var isEnabled: Bool {
        didSet {
            updateVisuals()
            window?.invalidateCursorRects(for: self)
        }
    }

    override var isHighlighted: Bool {
        didSet {
            updateVisuals()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled {
            isHovered = true
            updateVisuals()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateVisuals()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private func updateVisuals() {
        guard let layer = layer else { return }
        layer.borderWidth = 1.0

        guard isEnabled else {
            contentTintColor = NSColor.white.withAlphaComponent(0.20)
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.04).cgColor
            return
        }

        switch style {
        case .cancel:
            if isHighlighted {
                contentTintColor = NSColor.white
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
            } else if isHovered {
                contentTintColor = NSColor.white
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
            } else {
                contentTintColor = NSColor.white.withAlphaComponent(0.85)
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            }
        case .confirm:
            let baseBlue = NSColor(srgbRed: 44 / 255.0, green: 98 / 255.0, blue: 239 / 255.0, alpha: 0.92)
            let hoverBlue = NSColor(srgbRed: 58 / 255.0, green: 115 / 255.0, blue: 255 / 255.0, alpha: 1.0)
            let pressedBlue = NSColor(srgbRed: 36 / 255.0, green: 80 / 255.0, blue: 215 / 255.0, alpha: 1.0)

            if isHighlighted {
                contentTintColor = NSColor.white
                layer.backgroundColor = pressedBlue.cgColor
                layer.borderColor = NSColor(srgbRed: 100 / 255.0, green: 145 / 255.0, blue: 255 / 255.0, alpha: 0.60).cgColor
            } else if isHovered {
                contentTintColor = NSColor.white
                layer.backgroundColor = hoverBlue.cgColor
                layer.borderColor = NSColor(srgbRed: 130 / 255.0, green: 175 / 255.0, blue: 255 / 255.0, alpha: 0.85).cgColor
            } else {
                contentTintColor = NSColor.white
                layer.backgroundColor = baseBlue.cgColor
                layer.borderColor = NSColor(srgbRed: 90 / 255.0, green: 135 / 255.0, blue: 255 / 255.0, alpha: 0.45).cgColor
            }
        }
    }
}

@MainActor
private final class CapsuleWaveformView: NSView {
    private var levels: [CGFloat]
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0
    private var phase: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        self.levels = Array(repeating: 0, count: 21)
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
        smoothedLevel += (targetLevel - smoothedLevel) * (targetLevel > smoothedLevel ? 0.38 : 0.16)
        if smoothedLevel < 0.002 { smoothedLevel = 0 }
        phase += 0.22
        if phase > 2 * .pi { phase -= 2 * .pi }
        levels.removeFirst()
        levels.append(smoothedLevel)
        needsDisplay = true
    }

    func showStaticLevel() {
        smoothedLevel = targetLevel
        phase = 0
        levels = Array(repeating: targetLevel, count: levels.count)
        needsDisplay = true
    }

    func reset() {
        targetLevel = 0
        smoothedLevel = 0
        phase = 0
        levels = Array(repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let count = levels.count
        let barWidth: CGFloat = 2.2
        let cornerRadius: CGFloat = barWidth / 2.0
        let baselineHeight: CGFloat = 2.2
        let maxDynamicHeight: CGFloat = bounds.height - baselineHeight - 2.0
        let step = bounds.width / CGFloat(count)

        for (index, level) in levels.enumerated() {
            let normalizedX = CGFloat(index) / CGFloat(count - 1)
            let centerDist = abs(CGFloat(index) - CGFloat(count - 1) / 2.0) / CGFloat(count / 2)
            let envelope = max(0.52, 1.0 - 0.40 * centerDist)

            let height: CGFloat
            let alpha: CGFloat
            if level <= 0.002 {
                height = baselineHeight
                alpha = 0.32 + 0.12 * envelope
            } else {
                let harmonic = 1.0 + 0.14 * sin(CGFloat(index) * 0.70 + phase)
                let dynamic = pow(level, 0.65) * maxDynamicHeight * envelope * harmonic
                height = min(bounds.height, max(baselineHeight, baselineHeight + dynamic))
                alpha = min(1.0, 0.58 + 0.42 * pow(level, 0.5))
            }

            let barX = step * (CGFloat(index) + 0.5) - barWidth / 2.0
            let barRect = NSRect(
                x: barX,
                y: bounds.midY - height / 2.0,
                width: barWidth,
                height: height
            )

            let barColor: NSColor
            if normalizedX <= 0.5 {
                let ratio = normalizedX / 0.5
                let r = (52.0 + (44.0 - 52.0) * ratio) / 255.0
                let g = (125.0 + (98.0 - 125.0) * ratio) / 255.0
                let b = (248.0 + (239.0 - 248.0) * ratio) / 255.0
                barColor = NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            } else {
                let ratio = (normalizedX - 0.5) / 0.5
                let r = (44.0 + (104.0 - 44.0) * ratio) / 255.0
                let g = (98.0 + (92.0 - 98.0) * ratio) / 255.0
                let b = (239.0 + (242.0 - 239.0) * ratio) / 255.0
                barColor = NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            }

            barColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
    }
}
