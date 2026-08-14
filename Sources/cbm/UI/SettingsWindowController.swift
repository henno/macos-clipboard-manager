import AppKit

/// Settings, plus the live measurements behind this app's performance claims.
///
/// The metrics timer only runs while this window is on screen -- a settings
/// panel that woke the CPU once a second forever would undo the thing it is
/// there to demonstrate.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var metricsLabel: NSTextField!
    private var storageLabel: NSTextField!
    private var accessibilityLabel: NSTextField!
    private var accessibilityButton: NSButton!
    private var restartButton: NSButton!
    private var accessibilityHint: NSTextField!
    private var commandLabel: NSTextField!
    private var copyCommandButton: NSButton!
    private var loginCheckbox: NSButton!
    private var refreshTimer: Timer?

    private override init() { super.init() }

    @objc func show() {
        let window = buildIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        refresh()
        startRefreshing()
    }

    // MARK: - Construction

    private func buildIfNeeded() -> NSWindow {
        if let window { return window }

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        content.addArrangedSubview(header("History limits"))
        content.addArrangedSubview(numberRow(
            "Keep at most", suffix: "entries",
            value: Settings.shared.maxItems) { Settings.shared.maxItems = $0 })
        content.addArrangedSubview(numberRow(
            "Delete entries older than", suffix: "days (0 = never)",
            value: Settings.shared.maxAgeDays) { Settings.shared.maxAgeDays = $0 })
        content.addArrangedSubview(numberRow(
            "Delete images older than", suffix: "days (0 = never)",
            value: Settings.shared.imageMaxAgeDays) { Settings.shared.imageMaxAgeDays = $0 })
        content.addArrangedSubview(numberRow(
            "Skip anything larger than", suffix: "MB",
            value: Settings.shared.maxItemSizeMB) { Settings.shared.maxItemSizeMB = $0 })

        let applyButton = NSButton(title: "Apply limits now", target: self, action: #selector(applyLimits))
        applyButton.bezelStyle = .rounded
        content.addArrangedSubview(applyButton)

        content.addArrangedSubview(spacer())
        content.addArrangedSubview(header("General"))

        loginCheckbox = NSButton(
            checkboxWithTitle: "Launch cbm at login", target: self, action: #selector(toggleLogin))
        content.addArrangedSubview(loginCheckbox)

        accessibilityLabel = NSTextField(labelWithString: "")
        accessibilityLabel.font = .systemFont(ofSize: 11)
        content.addArrangedSubview(accessibilityLabel)

        let accessibilityButtons = NSStackView()
        accessibilityButtons.orientation = .horizontal
        accessibilityButtons.spacing = 8
        accessibilityButton = NSButton(
            title: "Open Accessibility settings", target: self, action: #selector(openAccessibility))
        accessibilityButton.bezelStyle = .rounded
        restartButton = NSButton(title: "Restart cbm", target: self, action: #selector(restart))
        restartButton.bezelStyle = .rounded
        accessibilityButtons.addArrangedSubview(accessibilityButton)
        accessibilityButtons.addArrangedSubview(restartButton)
        content.addArrangedSubview(accessibilityButtons)

        accessibilityHint = NSTextField(wrappingLabelWithString: "")
        accessibilityHint.font = .systemFont(ofSize: 10.5)
        accessibilityHint.textColor = .tertiaryLabelColor
        accessibilityHint.preferredMaxLayoutWidth = 400
        content.addArrangedSubview(accessibilityHint)

        commandLabel = NSTextField(labelWithString: "")
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.isSelectable = true
        content.addArrangedSubview(commandLabel)

        copyCommandButton = NSButton(
            title: "Copy command", target: self, action: #selector(copyStableSignatureCommand))
        copyCommandButton.bezelStyle = .rounded
        content.addArrangedSubview(copyCommandButton)

        content.addArrangedSubview(spacer())
        content.addArrangedSubview(header("Storage"))

        storageLabel = NSTextField(labelWithString: "")
        storageLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        storageLabel.textColor = .secondaryLabelColor
        content.addArrangedSubview(storageLabel)

        let storageButtons = NSStackView()
        storageButtons.orientation = .horizontal
        storageButtons.spacing = 8
        let reveal = NSButton(title: "Reveal data folder", target: self, action: #selector(revealData))
        reveal.bezelStyle = .rounded
        let clear = NSButton(title: "Clear history…", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        storageButtons.addArrangedSubview(reveal)
        storageButtons.addArrangedSubview(clear)
        content.addArrangedSubview(storageButtons)

        content.addArrangedSubview(spacer())
        content.addArrangedSubview(header("Live measurements"))

        metricsLabel = NSTextField(labelWithString: "")
        metricsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metricsLabel.textColor = .secondaryLabelColor
        content.addArrangedSubview(metricsLabel)

        let hint = NSTextField(wrappingLabelWithString:
            "Wakeups are what cost battery, not CPU percentage. The poll interval "
            + "adapts from 0.2 s just after a copy to 2 s when nothing has happened "
            + "for a minute, and stops entirely while the screen is locked.")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 400
        content.addArrangedSubview(hint)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "cbm Settings"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }

    private func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return view
    }

    private func numberRow(
        _ title: String, suffix: String, value: Int, onChange: @escaping (Int) -> Void
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)

        let field = NumberField(value: value, onCommit: onChange)

        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.font = .systemFont(ofSize: 11)
        suffixLabel.textColor = .secondaryLabelColor

        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        row.addArrangedSubview(suffixLabel)
        return row
    }

    // MARK: - Refresh

    private func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off

        let trusted = Paster.isTrusted
        accessibilityLabel.stringValue = trusted
            ? "Accessibility granted — Return pastes into the previous app."
            : "Accessibility not granted — Return only copies to the clipboard."
        accessibilityLabel.textColor = trusted ? .secondaryLabelColor : .systemOrange
        accessibilityButton.isHidden = trusted
        restartButton.isHidden = trusted

        // Everything below is troubleshooting for a permission that is not in
        // place. Once it is, none of it is worth a line of the user's attention.
        let command = CodeSignature.stableSignatureCommand
        let showSignatureAdvice = !trusted && CodeSignature.isAdHoc
        accessibilityHint.isHidden = trusted
        commandLabel.isHidden = !showSignatureAdvice || command == nil
        copyCommandButton.isHidden = commandLabel.isHidden

        if showSignatureAdvice {
            accessibilityHint.stringValue =
                "This build is ad-hoc signed, which means its signature is just a hash of "
                + "the binary. macOS ties permissions to that signature, so the next time "
                + "cbm is rebuilt it looks like a different app and the permission you "
                + "grant now is silently voided — the switch stays on but stops working. "
                + (command == nil
                   ? "Signing it with a certificate once fixes that for good."
                   : "To give it a stable signature, run this once in Terminal:")
            commandLabel.stringValue = command ?? ""
        } else if !trusted {
            accessibilityHint.stringValue =
                "If you have just granted the permission and this still says otherwise, "
                + "use Restart cbm."
            commandLabel.stringValue = ""
        }

        let snap = Metrics.shared.snapshot()
        let search = snap.lastSearchMicros > 0
            ? String(format: "%.0f µs over %d candidates", snap.lastSearchMicros, snap.lastSearchCandidates)
            : "—"
        metricsLabel.stringValue = """
            memory        \(ByteSize.string(Int64(snap.residentBytes)))
            search index  \(ByteSize.string(Int64(SearchIndex.shared.approximateBytes)))
            wakeups       \(String(format: "%.2f", snap.wakeupsPerSecond))/s  (\(snap.wakeups) in \(Int(snap.uptime)) s)
            clipboard reads  \(snap.pasteboardReads)
            last search   \(search)
            """

        // Directory sizes walk the filesystem, so they are refreshed off the
        // main thread rather than once a second on it.
        DispatchQueue.global(qos: .utility).async {
            let count = ItemStore.shared.count()
            let db = ItemStore.shared.databaseBytes()
            let blobs = ItemStore.shared.blobBytes()
            DispatchQueue.main.async { [weak self] in
                self?.storageLabel.stringValue = """
                    entries       \(count)
                    database      \(ByteSize.string(db))
                    blobs+thumbs  \(ByteSize.string(blobs))
                    """
            }
        }
    }

    // MARK: - Actions

    @objc private func applyLimits() {
        ItemStore.shared.sweep {
            SearchIndex.shared.rebuild(from: ItemStore.shared.recent())
            self.refresh()
        }
    }

    @objc private func toggleLogin() {
        let wanted = loginCheckbox.state == .on
        if !LoginItem.set(wanted) {
            loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        }
        Settings.shared.hasAskedAboutLogin = true
    }

    @objc private func openAccessibility() {
        Paster.requestTrust()
        Paster.openAccessibilitySettings()
    }

    /// Relaunches through a detached shell that outlives this process, which is
    /// the only way an app can restart itself.
    @objc private func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open -n \"\(path)\""]
        do {
            try task.run()
        } catch {
            Log.error("restart failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Written through the monitor so cbm does not record its own instruction
    /// as a history entry.
    @objc private func copyStableSignatureCommand() {
        guard let command = CodeSignature.stableSignatureCommand else { return }
        ClipboardMonitor.shared.write { pb in
            pb.setString(command, forType: .string)
        } completion: { [weak self] in
            self?.copyCommandButton.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.copyCommandButton.title = "Copy command"
            }
        }
    }

    @objc private func revealData() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.root.path)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete all clipboard history?"
        alert.informativeText = "Every stored entry, image and thumbnail will be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Everything")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ItemStore.shared.deleteAll {
            SearchIndex.shared.rebuild(from: [])
            self.refresh()
        }
    }
}

/// An integer field that reports its value when editing ends.
private final class NumberField: NSTextField, NSTextFieldDelegate {
    private let onCommit: (Int) -> Void

    init(value: Int, onCommit: @escaping (Int) -> Void) {
        self.onCommit = onCommit
        super.init(frame: .zero)

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 1_000_000
        self.formatter = formatter

        integerValue = value
        alignment = .right
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 70).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidEndEditing(_ obj: Notification) {
        onCommit(integerValue)
    }
}
