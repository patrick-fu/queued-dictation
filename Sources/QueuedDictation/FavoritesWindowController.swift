import AppKit
import DictationCore
import UniformTypeIdentifiers

@MainActor
final class FavoritesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: FavoritesStore
    private let copyToPasteboard: (String) -> Bool
    private let storageChanged: @MainActor () -> Void
    private let table = NSTableView()
    private let detail = NSTextView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton(title: "复制文本", target: nil, action: nil)
    private let downloadText = NSButton(title: "下载文本…", target: nil, action: nil)
    private let downloadJSON = NSButton(title: "下载 JSON…", target: nil, action: nil)
    private let delete = NSButton(title: "删除收藏…", target: nil, action: nil)
    private var favorites: [FavoriteFeedback] = []

    init(store: FavoritesStore, copyToPasteboard: @escaping (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }, storageChanged: @escaping @MainActor () -> Void = {}) {
        self.store = store; self.copyToPasteboard = copyToPasteboard; self.storageChanged = storageChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "带教收藏"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 500)
        window.center()
        for (title, name, width) in [("收藏时间", "date", 170.0), ("对应原文", "text", 490.0), ("建议", "count", 60.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.rowHeight = 30; table.allowsMultipleSelection = false
        let list = NSScrollView()
        list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        let content = NSScrollView()
        content.documentView = detail; content.hasVerticalScroller = true; content.borderType = .bezelBorder
        detail.isEditable = false; detail.isSelectable = true
        detail.font = .systemFont(ofSize: 13)
        detail.textContainerInset = NSSize(width: 12, height: 12)
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        for (button, action) in [(copy, #selector(copySelected)), (downloadText, #selector(exportSelectedText)),
                                  (downloadJSON, #selector(exportSelectedJSON)), (delete, #selector(deleteSelected))] {
            button.target = self; button.action = action
        }
        let actions = NSStackView(views: [copy, downloadText, downloadJSON, delete])
        actions.spacing = 8
        let help = NSTextField(wrappingLabelWithString: "收藏保留对应文本与完整建议，直到你主动删除。删除或清空语音历史后仍可复习；原音频沿用语音历史的保留期。")
        help.textColor = .secondaryLabelColor
        message.textColor = .systemRed
        message.maximumNumberOfLines = 3
        let stack = NSStackView(views: [summary, list, content, actions, help, message])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.heightAnchor.constraint(equalToConstant: 180),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateSelection()
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        reload()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let selection = selected?.id
        do {
            favorites = try store.entries()
            summary.stringValue = favorites.isEmpty ? "还没有带教收藏。可从带教卡片或语音历史收藏建议。" : "\(favorites.count) 条带教收藏"
            message.stringValue = ""
        } catch {
            favorites = []
            summary.stringValue = "收藏暂时无法读取。"
            message.stringValue = failureMessage(error)
        }
        table.reloadData()
        if !favorites.isEmpty {
            let row = selection.flatMap { id in favorites.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard favorites.indices.contains(row), let column = tableColumn else { return nil }
        let favorite = favorites[row]
        let value: String
        switch column.identifier.rawValue {
        case "date": value = favorite.createdAt.formatted(date: .numeric, time: .shortened)
        case "count": value = "\(favorite.feedback.suggestions.count) 条"
        default: value = String(favorite.rawText.prefix(90)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private var selected: FavoriteFeedback? {
        favorites.indices.contains(table.selectedRow) ? favorites[table.selectedRow] : nil
    }

    private func updateSelection() {
        var available = false
        if let favorite = selected {
            do { detail.string = try store.text(favorite.id); available = true }
            catch { detail.string = ""; message.stringValue = failureMessage(error) }
        } else { detail.string = "" }
        for button in [copy, downloadText, downloadJSON, delete] { button.isEnabled = available }
    }

    @objc private func copySelected() {
        guard let favorite = selected else { return }
        do {
            guard copyToPasteboard(try store.text(favorite.id)) else {
                message.stringValue = "未能写入剪贴板，请重试。"; return
            }
            message.stringValue = ""
        } catch { message.stringValue = failureMessage(error) }
    }

    @objc private func exportSelectedText() { exportSelected(json: false) }
    @objc private func exportSelectedJSON() { exportSelected(json: true) }

    private func exportSelected(json: Bool) {
        guard let favorite = selected, let window = table.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = json ? [.json] : [.plainText]
        panel.nameFieldStringValue = "带教收藏-\(favorite.id.uuidString.prefix(8)).\(json ? "json" : "txt")"
        panel.message = "下载文件包含这条收藏的明文文本和建议。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            do {
                if json { try self.store.exportJSON(favorite.id, to: destination) }
                else { try self.store.exportText(favorite.id, to: destination) }
                self.message.stringValue = ""
            } catch { self.message.stringValue = self.failureMessage(error) }
        }
    }

    @objc private func deleteSelected() {
        guard let favorite = selected, let window = table.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除这条带教收藏？"
        alert.informativeText = "该收藏的对应文本和建议将被删除。语音历史仍可单独管理。"
        alert.addButton(withTitle: "删除收藏")
        alert.addButton(withTitle: "保留")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            defer { self.storageChanged() }
            do { try self.store.delete(favorite.id); self.reload() }
            catch { self.message.stringValue = self.failureMessage(error) }
        }
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? FavoritesError)?.localizedDescription ?? "收藏操作未完成，请检查保存位置、钥匙串访问与可用空间。"
    }
}
