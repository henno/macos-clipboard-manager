import AppKit

/// The search panel.
///
/// Nothing in here is built until the hotkey is pressed for the first time. Up
/// to that point the process has never instantiated a window, a table view or a
/// text system -- which is most of what an AppKit app's resident memory is.
final class PanelController: NSObject {
    static let shared = PanelController()

    private enum Layout {
        static let windowSize = NSSize(width: 780, height: 480)
        static let listWidth: CGFloat = 330
        static let searchHeight: CGFloat = 34
        static let footerHeight: CGFloat = 22
    }

    private var window: PanelWindow?
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var listScroll: NSScrollView!
    private var preview: PreviewView!
    private var footer: NSTextField!
    private var emptyLabel: NSTextField!

    private var hits: [SearchHit] = []
    private var pasteTarget: NSRunningApplication?
    private var indexLoaded = false
    private var shownAt = Date.distantPast

    private override init() {
        super.init()
    }

    // MARK: - Show / hide

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { dismiss() } else { show() }
    }

    func show() {
        // Whom to paste back into -- captured before we steal focus.
        pasteTarget = FrontmostTracker.shared.target
        // Cheap insurance: if the cadence had dropped to idle, this picks up
        // anything copied since the last tick.
        ClipboardMonitor.shared.pollNow()

        loadIndexIfNeeded()
        let window = buildWindowIfNeeded()

        searchField.stringValue = ""
        runSearch("")
        position(window)

        shownAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        updateFooter()
    }

    /// Esc, click-away, or a completed copy-only action.
    func dismiss() {
        window?.orderOut(nil)
        // Hands activation back to whatever the user was in before.
        NSApp.hide(nil)
    }

    /// Used on the paste path, where we activate the target app ourselves and
    /// must not let AppKit pick a different one.
    private func hideForPaste() {
        window?.orderOut(nil)
    }

    private func position(_ window: PanelWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = Layout.windowSize
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.12)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        let items = ItemStore.shared.recent()
        SearchIndex.shared.rebuild(from: items)
        warmFavicons(for: items)
    }

    /// Favicon lookup reads a database, so it happens off the main thread and
    /// the list redraws once the icons are in hand. Until then rows show the
    /// application icon, which is what they showed before this existed.
    private func warmFavicons(for items: [ClipItem]) {
        let hosts = Set(items.compactMap(\.sourceHost))
        guard !hosts.isEmpty else { return }
        FaviconStore.shared.warm(hosts: hosts) { [weak self] foundAny in
            guard foundAny, let self, self.isVisible else { return }
            self.tableView.reloadData()
        }
    }

    // MARK: - Construction

    @discardableResult
    private func buildWindowIfNeeded() -> PanelWindow {
        if let window { return window }

        let window = PanelWindow(size: Layout.windowSize)
        guard let root = window.contentView else { fatalError("panel has no content view") }

        searchField = NSTextField()
        searchField.font = .systemFont(ofSize: 17, weight: .regular)
        searchField.placeholderString = "Search clipboard history…"
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false

        let topSeparator = separator()
        let midSeparator = separator()

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = ItemRowView.height
        tableView.rowSizeStyle = .custom
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false

        emptyLabel = NSTextField(labelWithString: "No matches")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true

        preview = PreviewView()

        footer = NSTextField(labelWithString: "")
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        for v in [searchField, topSeparator, listScroll, midSeparator, preview,
                  emptyLabel, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: Layout.searchHeight),

            topSeparator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: Layout.footerHeight),

            listScroll.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: Layout.listWidth),
            listScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),

            midSeparator.topAnchor.constraint(equalTo: listScroll.topAnchor),
            midSeparator.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
            midSeparator.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            midSeparator.widthAnchor.constraint(equalToConstant: 1),

            preview.topAnchor.constraint(equalTo: listScroll.topAnchor),
            preview.leadingAnchor.constraint(equalTo: midSeparator.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
        ])

        window.onKeyEquivalent = { [weak self] event in self?.handle(event) ?? false }
        window.onCancel = { [weak self] in self?.dismiss() }
        window.onResignKey = { [weak self] in
            guard let self, self.isVisible else { return }
            // Losing focus normally means the user clicked elsewhere, and the
            // panel should get out of the way. But a window can also resign key
            // in the same breath as it appears — when the app was launched into
            // the background, or something else grabs focus just then — and a
            // panel that closes the instant it opens is useless. Ignore the
            // first moment.
            guard Date().timeIntervalSince(self.shownAt) > 0.4 else { return }
            self.window?.orderOut(nil)
        }

        self.window = window
        return window
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    // MARK: - Search

    private func runSearch(_ query: String) {
        hits = SearchIndex.shared.search(query)
        tableView.reloadData()
        emptyLabel.isHidden = !hits.isEmpty
        if hits.isEmpty {
            preview.show(nil)
        } else {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Store change forwarding

    /// The index only tracks incremental changes once it has a baseline; before
    /// the first panel open there is nothing to keep up to date.
    func storeDidInsert(_ item: ClipItem) {
        guard indexLoaded else { return }
        SearchIndex.shared.insert(item)
        warmFavicons(for: [item])
        refreshIfVisible()
    }

    func storeDidTouch(id: Int64, updatedAt: Double) {
        guard indexLoaded else { return }
        SearchIndex.shared.touch(id: id, updatedAt: updatedAt)
        refreshIfVisible()
    }

    func storeDidDelete(ids: Set<Int64>) {
        guard indexLoaded else { return }
        SearchIndex.shared.remove(ids: ids)
        for id in ids {
            if let hash = hits.first(where: { $0.item.id == id })?.item.hash {
                ThumbCache.shared.evict(hash: hash)
            }
        }
        refreshIfVisible()
    }

    /// Called when the history changes underneath an open panel.
    func refreshIfVisible() {
        guard isVisible else { return }
        let selectedID = selectedItem?.id
        hits = SearchIndex.shared.search(searchField.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !hits.isEmpty
        if let selectedID, let row = hits.firstIndex(where: { $0.item.id == selectedID }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else if !hits.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    private var selectedItem: ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < hits.count else { return nil }
        return hits[row].item
    }

    // MARK: - Keyboard

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch (flags, key) {
        case ([.command], "\r"):
            activate(mode: .copyOnly); return true
        case ([.command, .shift], "\r"):
            activate(mode: .pastePlain); return true
        case ([.command], "\u{8}"), ([.command], "\u{7F}"):
            deleteSelected(); return true
        case ([.command], ","):
            dismiss(); SettingsWindowController.shared.show(); return true
        case ([.command], "w"):
            dismiss(); return true
        default:
            return false
        }
    }

    private func move(by delta: Int) {
        guard !hits.isEmpty else { return }
        let next = min(max(tableView.selectedRow + delta, 0), hits.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func handleDoubleClick() {
        guard tableView.clickedRow >= 0 else { return }
        activate(mode: .paste)
    }

    // MARK: - Actions

    private func activate(mode: Paster.Mode) {
        guard let item = selectedItem else { return }
        let target = pasteTarget

        if mode == .copyOnly {
            dismiss()
        } else {
            hideForPaste()
        }

        // Reading the payload touches the database, so keep it off the main
        // thread; the panel is already gone by the time this runs.
        DispatchQueue.global(qos: .userInitiated).async {
            let reps = ItemStore.shared.representations(of: item.id)
            DispatchQueue.main.async {
                Paster.perform(item: item, reps: reps, mode: mode, target: target)
                if mode != .copyOnly, !Paster.isTrusted {
                    self.explainMissingTrust()
                }
            }
        }
    }

    /// Without Accessibility, Return silently degrades to a plain copy -- which
    /// from the user's side looks like the key did nothing at all. Say so once,
    /// with the fix one click away.
    private func explainMissingTrust() {
        guard !Settings.shared.suppressTrustAlert else { return }

        let alert = NSAlert()
        alert.messageText = "Copied — but cbm could not paste it for you"
        alert.informativeText =
            "The entry is on your clipboard now, so ⌘V will paste it.\n\n"
            + "For cbm to press ⌘V for you, macOS needs to grant it the Accessibility "
            + "permission. Open the settings, switch cbm on in the list, then use "
            + "Restart cbm in cbm's own settings — macOS only notices the change when "
            + "the app restarts."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Stop reminding me; copying is fine"

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            Settings.shared.suppressTrustAlert = true
        }
        if response == .alertFirstButtonReturn {
            Paster.requestTrust()
            Paster.openAccessibilitySettings()
        }
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = tableView.selectedRow
        ItemStore.shared.delete(ids: [item.id])
        SearchIndex.shared.remove(ids: [item.id])
        hits.remove(at: row)
        tableView.reloadData()
        emptyLabel.isHidden = !hits.isEmpty
        if hits.isEmpty {
            preview.show(nil)
        } else {
            let next = min(row, hits.count - 1)
            tableView.selectRowIndexes([next], byExtendingSelection: false)
        }
    }

    private func updateFooter() {
        if Paster.isTrusted {
            footer.stringValue = "↵ paste   ⌘↵ copy   ⇧⌘↵ plain text   ⌘⌫ delete   app: filters by source"
            footer.textColor = .tertiaryLabelColor
        } else {
            footer.stringValue = "↵ copies only — grant Accessibility in Settings (⌘,) to paste automatically"
            footer.textColor = .systemOrange
        }
    }
}

// MARK: - Table data

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < hits.count else { return nil }
        let view = tableView.makeView(withIdentifier: ItemRowView.identifier, owner: self) as? ItemRowView
            ?? {
                let v = ItemRowView(frame: .zero)
                v.identifier = ItemRowView.identifier
                return v
            }()
        let hit = hits[row]
        view.configure(with: hit.item, highlight: SearchIndex.shared.highlightPositions(for: hit))
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        preview.show(selectedItem)
    }
}

// MARK: - Search field

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        runSearch(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1); return true
        // Page Down/Up, and the Option+arrow equivalents a laptop keyboard sends
        // instead (a single-line field editor reads those as paragraph motion).
        case #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.moveToEndOfParagraph(_:)),
             #selector(NSResponder.moveToEndOfDocument(_:)):
            move(by: 8); return true
        case #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.moveToBeginningOfParagraph(_:)),
             #selector(NSResponder.moveToBeginningOfDocument(_:)):
            move(by: -8); return true
        case #selector(NSResponder.insertNewline(_:)):
            activate(mode: .paste); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); return true
        default:
            return false
        }
    }
}
