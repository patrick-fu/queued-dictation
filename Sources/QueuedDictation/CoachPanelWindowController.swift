import AppKit
import DictationCore

@MainActor
final class CoachPanelWindowController: NSWindowController, NSWindowDelegate {
    private let scheduler: CoachWorkScheduler
    private let currentInputScreen: () -> NSScreen?
    private let onFavorite: ((CoachCard) throws -> Void)?
    private let scroll = NSScrollView()
    private let cardDocument = CoachPanelDocumentView()
    private let cards = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private enum FavoriteOutcome { case saved, failed }
    private var favoriteOutcomes: [CoachWorkIdentity: FavoriteOutcome] = [:]
    private var favoriteButtons: [CoachWorkIdentity: CoachFavoriteCardButton] = [:]
    private var savingFavorites: Set<CoachWorkIdentity> = []
    private var displayed: [CoachCard] = []
    private var lastScreenID: NSNumber?
    private var lastCorner: CoachCorner?

    init(scheduler: CoachWorkScheduler, currentInputScreen: @escaping () -> NSScreen? = { nil },
         onFavorite: ((CoachCard) throws -> Void)? = nil) {
        self.scheduler = scheduler; self.currentInputScreen = currentInputScreen
        self.onFavorite = onFavorite
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
        let mode = NSTextField(wrappingLabelWithString: "每张卡片标明本次实际使用的带教方式")
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
            favoriteOutcomes.removeAll()
            clearCards()
            return
        }
        let hasArrival = state.cards.contains { card in !displayed.contains(where: { $0.identity == card.identity }) }
        if hasArrival || window?.isVisible != true || lastCorner != scheduler.configuration.corner { dockForArrival() }
        if displayed != state.cards {
            favoriteOutcomes = favoriteOutcomes.filter { identity, _ in
                displayed.first(where: { $0.identity == identity }).map { state.cards.contains($0) } ?? false
            }
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
        favoriteButtons.removeAll()
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
        let top = NSStackView(views: [heading])
        var favorite: CoachFavoriteCardButton?
        if onFavorite != nil {
            let button = CoachFavoriteCardButton(title: "收藏", target: self, action: #selector(favoriteCard(_:)))
            button.card = card
            button.isEnabled = !savingFavorites.contains(card.identity)
            button.controlSize = .small
            button.refusesFirstResponder = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            favorite = button
            favoriteButtons[card.identity] = button
            top.addArrangedSubview(button)
        }
        top.addArrangedSubview(remove)
        top.distribution = .fill; top.spacing = 8
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let source = NSTextField(wrappingLabelWithString: card.inputMode == .originalAudio
            ? "本次已发送原始音频和文本 · 流利度依据见建议"
            : "本次仅文本 · 无音频，不能评价流利度")
        source.textColor = .secondaryLabelColor; source.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [top])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let favorite {
            favorite.message.font = .systemFont(ofSize: 11)
            favorite.message.isHidden = true
            if let outcome = favoriteOutcomes[card.identity] { showFavoriteOutcome(outcome, on: favorite) }
            stack.addArrangedSubview(favorite.message)
            favorite.message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(source)
        for suggestion in card.feedback.suggestions {
            let categoryName: String = switch suggestion.category {
            case .grammar: "语法"
            case .expression: "表达"
            case .fluency: "流利度"
            }
            let category = NSTextField(labelWithString: categoryName)
            category.font = .systemFont(ofSize: 12, weight: .semibold)
            let original: NSTextField
            if let evidence = suggestion.audioEvidence {
                original = NSTextField(wrappingLabelWithString: String(format: "音频依据 %.3f–%.3f 秒：%@",
                    evidence.startSeconds, evidence.endSeconds, evidence.observation))
            } else { original = NSTextField(wrappingLabelWithString: "原表达：\(suggestion.original)") }
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
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    @objc private func removeCard(_ sender: CoachRemoveCardButton) {
        guard let id = sender.segmentID else { return }
        scheduler.removeCard(id)
        render()
    }

    @objc private func favoriteCard(_ sender: CoachFavoriteCardButton) {
        guard let card = sender.card, let onFavorite, currentFavorite(for: card) === sender,
              !savingFavorites.contains(card.identity) else { return }
        savingFavorites.insert(card.identity)
        sender.isEnabled = false
        defer {
            savingFavorites.remove(card.identity)
            currentFavorite(for: card)?.isEnabled = true
        }
        let outcome: FavoriteOutcome
        do {
            try onFavorite(card)
            outcome = .saved
        } catch { outcome = .failed }
        guard let current = currentFavorite(for: card) else { return }
        favoriteOutcomes[card.identity] = outcome
        showFavoriteOutcome(outcome, on: current)
    }

    private func currentFavorite(for card: CoachCard) -> CoachFavoriteCardButton? {
        guard scheduler.panelState.enabled, scheduler.panelState.cards.contains(card),
              let button = favoriteButtons[card.identity], button.card == card,
              let window, button.window === window else { return nil }
        return button
    }

    private func showFavoriteOutcome(_ outcome: FavoriteOutcome, on button: CoachFavoriteCardButton) {
        button.message.stringValue = outcome == .saved ? "已收藏。" : "未能保存收藏，请重试。"
        button.message.textColor = outcome == .saved ? .secondaryLabelColor : .systemRed
        button.message.isHidden = false
    }
}

private final class CoachNonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class CoachPanelDocumentView: NSView { override var isFlipped: Bool { true } }
private final class CoachRemoveCardButton: NSButton { var segmentID: UUID? }
private final class CoachFavoriteCardButton: NSButton {
    var card: CoachCard?
    let message = NSTextField(wrappingLabelWithString: "")
}
