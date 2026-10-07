import AppKit

// MARK: - Color Palette
private extension NSColor {
    static let appBackground = NSColor(red: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1.0) // #F8F9FB
    static let cardBackground = NSColor.white                                                           // #FFFFFF
    static let primaryText = NSColor(red: 0x24/255.0, green: 0x29/255.0, blue: 0x36/255.0, alpha: 1.0)   // #242936
    static let secondaryText = NSColor(red: 0x85/255.0, green: 0x8D/255.0, blue: 0x9C/255.0, alpha: 1.0) // #858D9C
    static let lightBorder = NSColor(red: 0xE5/255.0, green: 0xE7/255.0, blue: 0xED/255.0, alpha: 1.0)   // #E5E7ED
    static let primaryBlue = NSColor(red: 0x2C/255.0, green: 0x62/255.0, blue: 0xEF/255.0, alpha: 1.0)   // #2C62EF
    static let selectionGray = NSColor(red: 0xEC/255.0, green: 0xEE/255.0, blue: 0xF2/255.0, alpha: 1.0) // #ECEEF2
    static let selectionHover = NSColor(red: 0xF2/255.0, green: 0xF4/255.0, blue: 0xF7/255.0, alpha: 1.0)
    static let capsuleTrack = NSColor(red: 0xF0/255.0, green: 0xF2/255.0, blue: 0xF5/255.0, alpha: 1.0)  // #F0F2F5
    static let brandOrange = NSColor(red: 0xFF/255.0, green: 0x8D/255.0, blue: 0x1A/255.0, alpha: 1.0)   // #FF8D1A
    static let recordingRed = NSColor(red: 0xE0/255.0, green: 0x3E/255.0, blue: 0x3E/255.0, alpha: 1.0)
    static let disabledBg = NSColor(red: 0xEE/255.0, green: 0xF0/255.0, blue: 0xF3/255.0, alpha: 1.0)
}

// MARK: - MainWindowController
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
    private let titleStack: NSStackView
    private let capsuleTabBar = CapsuleTabBar()
    private let recordingButton: PrimaryActionButton
    private let body = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let shortcutHint = NSTextField(wrappingLabelWithString: "在任意输入框按 Fn\n开始，再按一次结束。")
    private var navigationItems: [SidebarNavItem] = []
    private var tabAction: ((Int) -> Void)?
    private var mountedView: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let recButton = PrimaryActionButton(title: "开始录音", target: nil, action: nil)
        self.recordingButton = recButton
        self.titleStack = NSStackView(views: [titleLabel, subtitleLabel])

        super.init(window: window)
        window.title = "Queued Dictation"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 700)
        window.backgroundColor = .appBackground
        window.delegate = self
        window.center()

        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.appBackground.cgColor

        // MARK: Sidebar (Width 200, Solid #F8F9FB)
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.appBackground.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        // Brand Row (Clearing traffic lights)
        let brandRow = NSStackView()
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 10
        brandRow.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(brandRow)

        let brandIcon = NSView()
        brandIcon.wantsLayer = true
        brandIcon.layer?.backgroundColor = NSColor.brandOrange.cgColor
        brandIcon.layer?.cornerRadius = 7
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        brandIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let iconImg = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "Queued Dictation")?.withSymbolConfiguration(symbolConfig) ?? NSImage())
        iconImg.contentTintColor = .white
        iconImg.translatesAutoresizingMaskIntoConstraints = false
        brandIcon.addSubview(iconImg)
        NSLayoutConstraint.activate([
            iconImg.centerXAnchor.constraint(equalTo: brandIcon.centerXAnchor),
            iconImg.centerYAnchor.constraint(equalTo: brandIcon.centerYAnchor)
        ])

        let brandLabel = NSTextField(labelWithString: "Queued Dictation")
        brandLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brandLabel.textColor = .primaryText

        brandRow.addArrangedSubview(brandIcon)
        brandRow.addArrangedSubview(brandLabel)

        // Navigation Stack
        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navStack)

        for page in Page.allCases {
            let item = SidebarNavItem(page: page, target: self, action: #selector(selectPage(_:)))
            navStack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
            item.heightAnchor.constraint(equalToConstant: 38).isActive = true
            navigationItems.append(item)
        }

        // Bottom Shortcut Hint
        shortcutHint.font = .systemFont(ofSize: 11.5)
        shortcutHint.textColor = .secondaryText
        shortcutHint.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(shortcutHint)

        // MARK: White Content Panel Card (#FFFFFF, corner radius 16, border #E5E7ED)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.cardBackground.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderColor = NSColor.lightBorder.cgColor
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        // Header Area
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(headerContainer)

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .primaryText
        subtitleLabel.font = .systemFont(ofSize: 12.5)
        subtitleLabel.textColor = .secondaryText
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(titleStack)

        capsuleTabBar.translatesAutoresizingMaskIntoConstraints = false
        capsuleTabBar.onSelectTab = { [weak self] index in
            self?.tabAction?(index)
        }
        headerContainer.addSubview(capsuleTabBar)

        recButton.target = self
        recButton.action = #selector(toggleRecording)
        headerContainer.addSubview(recButton)

        // Scrollable Body
        body.hasVerticalScroller = true
        body.autohidesScrollers = true
        body.drawsBackground = false
        body.borderType = .noBorder
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)

        // Bottom Status Label
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryText
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)

        // Constraints
        NSLayoutConstraint.activate([
            // Sidebar
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            brandRow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            brandRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            brandRow.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),

            navStack.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 22),
            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            navStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),

            shortcutHint.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            shortcutHint.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            shortcutHint.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22),

            // Content Card
            card.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            // Header Container
            headerContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            headerContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            headerContainer.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            headerContainer.heightAnchor.constraint(equalToConstant: 44),

            titleStack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: recButton.leadingAnchor, constant: -16),

            capsuleTabBar.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
            capsuleTabBar.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            capsuleTabBar.leadingAnchor.constraint(greaterThanOrEqualTo: headerContainer.leadingAnchor),
            capsuleTabBar.trailingAnchor.constraint(lessThanOrEqualTo: recButton.leadingAnchor, constant: -16),

            recButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            recButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            // Body ScrollView
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            // Status Label
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            statusLabel.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ page: Page, subtitle: String, content: NSView, tabTitles: [String] = [], selectedTab: Int = 0,
              onTab: ((Int) -> Void)? = nil) {
        onLeavePage?()
        currentPage = page
        tabAction = onTab

        for item in navigationItems {
            item.isSelected = (item.page == page)
        }

        if !tabTitles.isEmpty {
            capsuleTabBar.isHidden = false
            capsuleTabBar.setItems(tabTitles, selected: selectedTab)
            titleStack.isHidden = true
        } else {
            capsuleTabBar.isHidden = true
            titleStack.isHidden = false
            titleLabel.stringValue = page.title
            subtitleLabel.stringValue = subtitle
        }

        if mountedView !== content {
            NSLayoutConstraint.deactivate(activeContentConstraints)
            activeContentConstraints.removeAll()

            mountedView?.removeFromSuperview()

            let document = MainPageDocumentView()
            document.translatesAutoresizingMaskIntoConstraints = false
            body.documentView = document

            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(content)

            var constraints: [NSLayoutConstraint] = [
                document.topAnchor.constraint(equalTo: body.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: body.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: body.contentView.trailingAnchor),
                document.widthAnchor.constraint(equalTo: body.contentView.widthAnchor),

                content.topAnchor.constraint(equalTo: document.topAnchor),
                content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
                content.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
                content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 28),
                content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28)
            ]

            let preferredWidth = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -56)
            preferredWidth.priority = .defaultHigh
            constraints.append(preferredWidth)

            let hasInnerScrollView = content.subviews.contains { $0 is NSScrollView }
            if hasInnerScrollView {
                let matchViewport = document.heightAnchor.constraint(equalTo: body.contentView.heightAnchor)
                matchViewport.priority = NSLayoutConstraint.Priority(999)
                constraints.append(matchViewport)
            } else {
                let minViewport = document.heightAnchor.constraint(greaterThanOrEqualTo: body.contentView.heightAnchor)
                minViewport.priority = .defaultLow
                constraints.append(minViewport)

                if let stack = content.subviews.first(where: { $0 is NSStackView }) as? NSStackView {
                    let required = stack.fittingSize.height + 40
                    if required > 0 {
                        let reqConstraint = content.heightAnchor.constraint(greaterThanOrEqualToConstant: required)
                        reqConstraint.priority = NSLayoutConstraint.Priority(749)
                        constraints.append(reqConstraint)
                    }
                }
            }

            NSLayoutConstraint.activate(constraints)
            activeContentConstraints = constraints
            mountedView = content
        } else if !tabTitles.isEmpty {
            capsuleTabBar.selectTab(at: selectedTab)
        }

        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func reopen() {
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func isShowing(_ page: Page) -> Bool {
        currentPage == page && window?.isVisible == true
    }

    func renderStatus(_ message: String) {
        statusLabel.toolTip = message
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        let sanitized = message.replacingOccurrences(of: uuidPattern, with: "片段", options: .regularExpression)
        statusLabel.stringValue = sanitized
    }

    func renderShortcut(name: String, toggle: Bool) {
        shortcutHint.stringValue = toggle ? "在任意输入框按 \(name)\n开始，再按一次结束。" : "在任意输入框按住 \(name)\n说话，松开结束。"
    }

    func renderRecordingAction(title: String, enabled: Bool) {
        recordingButton.render(title: title, enabled: enabled)
    }

    func windowWillClose(_ notification: Notification) { onLeavePage?() }
    func windowDidResignKey(_ notification: Notification) { onLeavePage?() }

    @objc private func selectPage(_ sender: NSButton) {
        if let page = Page(rawValue: sender.tag) { onSelect?(page) }
    }

    @objc private func toggleRecording() {
        onToggleRecording?()
    }
}

// MARK: - Private Helper Classes

private final class MainPageDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarNavItem: NSButton {
    let page: MainWindowController.Page
    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }
    private var isHovered: Bool = false {
        didSet { updateAppearance() }
    }

    init(page: MainWindowController.Page, target: AnyObject?, action: Selector?) {
        self.page = page
        super.init(frame: .zero)
        self.tag = page.rawValue
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 9
        self.layer?.masksToBounds = true
        self.imagePosition = .imageLeading
        self.imageScaling = .scaleProportionallyDown
        self.alignment = .left
        self.translatesAutoresizingMaskIntoConstraints = false

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        self.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)?
            .withSymbolConfiguration(symbolConfig)

        setAccessibilityRole(.button)
        setAccessibilityLabel(page.title)

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)

        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updateAppearance() {
        setAccessibilitySelected(isSelected)
        if isSelected {
            layer?.backgroundColor = NSColor.selectionGray.cgColor
            contentTintColor = .primaryText
            attributedTitle = NSAttributedString(string: "  " + page.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: NSColor.primaryText
            ])
        } else {
            layer?.backgroundColor = isHovered ? NSColor.selectionHover.cgColor : NSColor.clear.cgColor
            contentTintColor = .secondaryText
            attributedTitle = NSAttributedString(string: "  " + page.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
                .foregroundColor: NSColor.secondaryText
            ])
        }
    }
}

private final class CapsuleTabBar: NSView {
    var onSelectTab: ((Int) -> Void)?
    private let stack = NSStackView()
    private var buttons: [CapsuleTabButton] = []
    private(set) var selectedIndex: Int = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.capsuleTrack.cgColor
        layer?.cornerRadius = 18
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setItems(_ titles: [String], selected: Int) {
        for btn in buttons {
            stack.removeArrangedSubview(btn)
            btn.removeFromSuperview()
        }
        buttons.removeAll()
        selectedIndex = selected

        for (index, title) in titles.enumerated() {
            let button = CapsuleTabButton(title: title, index: index, target: self, action: #selector(tabClicked(_:)))
            button.isSelected = (index == selected)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
    }

    func selectTab(at index: Int) {
        selectedIndex = index
        for (i, btn) in buttons.enumerated() {
            btn.isSelected = (i == index)
        }
    }

    @objc private func tabClicked(_ sender: CapsuleTabButton) {
        selectTab(at: sender.index)
        onSelectTab?(sender.index)
    }
}

private final class CapsuleTabButton: NSButton {
    let index: Int
    var isSelected: Bool = false {
        didSet { updateStyle() }
    }

    init(title: String, index: Int, target: AnyObject?, action: Selector?) {
        self.index = index
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 15
        self.layer?.masksToBounds = false
        self.translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        updateStyle()
    }

    required init?(coder: NSCoder) { nil }

    private func updateStyle() {
        setAccessibilityValue(isSelected ? "1" : "0")
        if isSelected {
            layer?.backgroundColor = NSColor.white.cgColor
            layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
            layer?.shadowOffset = CGSize(width: 0, height: 1)
            layer?.shadowRadius = 2
            layer?.shadowOpacity = 1
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.primaryText
            ])
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.shadowOpacity = 0
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.secondaryText
            ])
        }
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]).width
        return NSSize(width: max(textWidth + 28, 64), height: 30)
    }
}

private final class PrimaryActionButton: NSButton {
    private var isRecording: Bool = false

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true
        self.translatesAutoresizingMaskIntoConstraints = false
        render(title: title, enabled: true)
    }

    required init?(coder: NSCoder) { nil }

    func render(title: String, enabled: Bool) {
        self.isEnabled = enabled
        self.isRecording = title.contains("结束")

        let bgColor: NSColor
        let fgColor: NSColor
        if !enabled {
            bgColor = .disabledBg
            fgColor = .secondaryText
        } else if isRecording {
            bgColor = .recordingRed
            fgColor = .white
        } else {
            bgColor = .primaryBlue
            fgColor = .white
        }
        layer?.backgroundColor = bgColor.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: fgColor
        ])
    }

    override var intrinsicContentSize: NSSize {
        let superSize = super.intrinsicContentSize
        return NSSize(width: max(superSize.width + 24, 88), height: 34)
    }
}
