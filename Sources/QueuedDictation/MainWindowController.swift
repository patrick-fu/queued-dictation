import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum Page: Int, CaseIterable {
        case history, queue, models, coach, favorites, settings
        var title: String { ["历史记录", "待交付队列", "模型", "英语带教", "收藏", "设置"][rawValue] }
        var symbol: String { ["clock", "text.line.first.and.arrowtriangle.forward", "cpu", "bubble.left.and.text.bubble.right", "star", "gearshape"][rawValue] }
    }
    var onSelect: ((Page) -> Void)?
    var onLeavePage: (() -> Void)?
    var onToggleRecording: (() -> Void)?
    private(set) var currentPage: Page = .history
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSSegmentedControl()
    private let body = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutHint = NSTextField(wrappingLabelWithString: "在任意输入框按 Fn\n开始，再按一次结束。")
    private let recordingButton = NSButton(title: "开始录音", target: nil, action: nil)
    private var navigation: [NSButton] = []
    private var tabAction: ((Int) -> Void)?
    private var mountedView: NSView?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Queued Dictation"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1060, height: 720)
        window.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        window.delegate = self
        window.center()
        let root = window.contentView!
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        let brand = NSTextField(labelWithString: "Queued Dictation")
        brand.font = .systemFont(ofSize: 16, weight: .semibold)
        let brandIcon = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "语音输入")!)
        brandIcon.contentTintColor = .controlAccentColor
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        brandIcon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let brandRow = NSStackView(views: [brandIcon, brand])
        brandRow.spacing = 9
        let stack = NSStackView(views: [brandRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        stack.setCustomSpacing(28, after: brandRow)
        for page in Page.allCases {
            let item = NSButton(title: page.title, image: NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)!, target: self, action: #selector(selectPage(_:)))
            item.tag = page.rawValue
            item.imagePosition = .imageLeading
            item.imageScaling = .scaleProportionallyDown
            item.alignment = .left
            item.font = .systemFont(ofSize: 14, weight: .medium)
            item.isBordered = false
            item.wantsLayer = true
            item.layer?.cornerRadius = 10
            item.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            item.heightAnchor.constraint(equalToConstant: 40).isActive = true
            navigation.append(item)
        }
        let hint = shortcutHint
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(hint)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        tabs.segmentStyle = .rounded
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(selectTab(_:))
        let header = NSStackView(views: [titleLabel, subtitleLabel, tabs])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)
        recordingButton.target = self
        recordingButton.action = #selector(toggleRecording)
        recordingButton.bezelStyle = .rounded
        recordingButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(recordingButton)
        body.hasVerticalScroller = true
        body.autohidesScrollers = true
        body.drawsBackground = false
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 210),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 66),
            hint.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 23), hint.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24),
            card.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12), card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 42), card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28), header.trailingAnchor.constraint(lessThanOrEqualTo: recordingButton.leadingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            recordingButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28), recordingButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8), body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18), body.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28), statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ page: Page, subtitle: String, content: NSView, tabTitles: [String] = [], selectedTab: Int = 0,
              onTab: ((Int) -> Void)? = nil) {
        onLeavePage?()
        currentPage = page
        titleLabel.stringValue = page.title
        subtitleLabel.stringValue = subtitle
        tabAction = onTab
        tabs.segmentCount = tabTitles.count
        tabs.isHidden = tabTitles.isEmpty
        for (index, title) in tabTitles.enumerated() { tabs.setLabel(title, forSegment: index); tabs.setWidth(0, forSegment: index) }
        if !tabTitles.isEmpty { tabs.selectedSegment = selectedTab }
        for item in navigation {
            item.layer?.backgroundColor = item.tag == page.rawValue ? NSColor.quaternaryLabelColor.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
            item.contentTintColor = item.tag == page.rawValue ? .labelColor : .secondaryLabelColor
        }
        if mountedView !== content {
            let height = max(content.frame.height, content.fittingSize.height)
            mountedView?.removeFromSuperview()
            let document = MainPageDocumentView()
            document.translatesAutoresizingMaskIntoConstraints = false
            body.documentView = document
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(content)
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: body.contentView.widthAnchor),
                content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                content.heightAnchor.constraint(greaterThanOrEqualToConstant: height)
            ])
            mountedView = content
        }
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func reopen() { showWindow(nil); NSApp.activate(); window?.makeKeyAndOrderFront(nil) }
    func isShowing(_ page: Page) -> Bool { currentPage == page && window?.isVisible == true }
    func renderStatus(_ message: String) { statusLabel.stringValue = message; statusLabel.toolTip = message }
    func renderShortcut(name: String, toggle: Bool) {
        shortcutHint.stringValue = toggle ? "在任意输入框按 \(name)\n开始，再按一次结束。" : "在任意输入框按住 \(name)\n说话，松开结束。"
    }
    func renderRecordingAction(title: String, enabled: Bool) { recordingButton.title = title; recordingButton.isEnabled = enabled }
    func windowWillClose(_ notification: Notification) { onLeavePage?() }
    func windowDidResignKey(_ notification: Notification) { onLeavePage?() }
    @objc private func selectPage(_ sender: NSButton) { if let page = Page(rawValue: sender.tag) { onSelect?(page) } }
    @objc private func selectTab(_ sender: NSSegmentedControl) { tabAction?(sender.selectedSegment) }
    @objc private func toggleRecording() { onToggleRecording?() }
}

private final class MainPageDocumentView: NSView {
    override var isFlipped: Bool { true }
}
