import AppKit
import DictationCore

@MainActor
final class CoachPanelWindowController: NSWindowController, NSWindowDelegate {
    private let scheduler: CoachWorkScheduler
    private let currentInputScreen: () -> NSScreen?
    private let scroll = NSScrollView()
    private let cardDocument = CoachPanelDocumentView()
    private let cards = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var displayed: [CoachCard] = []
    private var lastScreenID: NSNumber?
    private var lastCorner: CoachCorner?

    init(scheduler: CoachWorkScheduler, currentInputScreen: @escaping () -> NSScreen? = { nil }) {
        self.scheduler = scheduler; self.currentInputScreen = currentInputScreen
        let panel = CoachNonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 550),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "英语带教"
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let content = panel.contentView!
        let mode = NSTextField(wrappingLabelWithString: "文本带教 · 无音频，不能评价流利度")
        mode.textColor = .secondaryLabelColor
        mode.font = .systemFont(ofSize: 11)
        let header = NSStackView(views: [countLabel, mode])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 6
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        for view in [header, scroll, errorLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        cardDocument.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = cardDocument
        cards.orientation = .vertical; cards.alignment = .leading; cards.spacing = 10
        cards.translatesAutoresizingMaskIntoConstraints = false
        cardDocument.addSubview(cards)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -6),
            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            errorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            errorLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            cardDocument.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cards.topAnchor.constraint(equalTo: cardDocument.topAnchor, constant: 4),
            cards.leadingAnchor.constraint(equalTo: cardDocument.leadingAnchor, constant: 12),
            cards.trailingAnchor.constraint(equalTo: cardDocument.trailingAnchor, constant: -12),
            cards.bottomAnchor.constraint(equalTo: cardDocument.bottomAnchor, constant: -10)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(displayEnvironmentChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayEnvironmentChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        render()
    }
    required init?(coder: NSCoder) { nil }

    func render() {
        let state = scheduler.panelState
        guard state.enabled, !state.cards.isEmpty else {
            displayed = []; window?.orderOut(nil)
            clearCards()
            return
        }
        let hasArrival = state.cards.contains { card in !displayed.contains(where: { $0.identity == card.identity }) }
        if hasArrival || window?.isVisible != true || lastCorner != scheduler.configuration.corner { dockForArrival() }
        if displayed != state.cards {
            let previousOrigin = scroll.contentView.bounds.origin
            clearCards()
            for card in state.cards {
                let view = cardView(card)
                cards.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
            }
            displayed = state.cards
            window?.contentView?.layoutSubtreeIfNeeded()
            if hasArrival { cardDocument.scroll(NSPoint(x: 0, y: max(0, cardDocument.bounds.height - scroll.contentView.bounds.height))) }
            else { cardDocument.scroll(previousOrigin) }
        }
        countLabel.stringValue = "英语带教 · \(state.cards.count) 张卡片"
        errorLabel.stringValue = ""
        window?.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try scheduler.setEnabled(false); render(); return true }
        catch { errorLabel.stringValue = "未能保存关闭设置，请重试。"; return false }
    }

    @objc private func displayEnvironmentChanged() {
        guard scheduler.panelState.enabled, !scheduler.panelState.cards.isEmpty else { return }
        dockForArrival()
        window?.orderFrontRegardless()
    }

    private func dockForArrival() {
        let screen = currentInputScreen()
            ?? NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == lastScreenID })
            ?? NSScreen.screens.first
        guard let screen, let window else { return }
        lastScreenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let visible = screen.visibleFrame, margin: CGFloat = 18
        let size = NSSize(width: min(380, max(100, visible.width - margin * 2)),
                          height: min(550, max(100, visible.height - margin * 2)))
        let corner = scheduler.configuration.corner
        lastCorner = corner
        let right = corner == .bottomRight || corner == .topRight
        let top = corner == .topRight || corner == .topLeft
        window.setFrame(NSRect(x: right ? visible.maxX - size.width - margin : visible.minX + margin,
                               y: top ? visible.maxY - size.height - margin : visible.minY + margin,
                               width: size.width, height: size.height), display: true)
    }

    private func clearCards() {
        for view in cards.arrangedSubviews { cards.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    private func cardView(_ card: CoachCard) -> NSView {
        let box = NSBox()
        box.boxType = .custom; box.borderWidth = 1
        box.borderColor = .separatorColor; box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 12, height: 12)
        let heading = NSTextField(labelWithString: "片段 \(card.identity.segmentID.uuidString.prefix(8))")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let remove = CoachRemoveCardButton(title: "看完并移走", target: self, action: #selector(removeCard(_:)))
        remove.segmentID = card.identity.segmentID
        remove.controlSize = .small
        remove.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [heading, remove])
        top.distribution = .fill; top.spacing = 8
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [top])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for suggestion in card.feedback.suggestions {
            let category = NSTextField(labelWithString: suggestion.category == .grammar ? "语法" : "表达")
            category.font = .systemFont(ofSize: 12, weight: .semibold)
            let original = NSTextField(wrappingLabelWithString: "原表达：\(suggestion.original)")
            original.textColor = .secondaryLabelColor
            let improved = NSTextField(wrappingLabelWithString: "建议：\(suggestion.improved)")
            improved.textColor = .systemGreen
            improved.font = .systemFont(ofSize: 13, weight: .medium)
            let reason = NSTextField(wrappingLabelWithString: suggestion.reason)
            reason.font = .systemFont(ofSize: 12)
            for label in [category, original, improved, reason] {
                stack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    @objc private func removeCard(_ sender: CoachRemoveCardButton) {
        guard let id = sender.segmentID else { return }
        scheduler.removeCard(id)
        render()
    }
}

private final class CoachNonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class CoachPanelDocumentView: NSView { override var isFlipped: Bool { true } }
private final class CoachRemoveCardButton: NSButton { var segmentID: UUID? }
