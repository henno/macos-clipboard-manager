import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only the status item and the pasteboard poller are built at launch.
        // The panel -- and with it the table view, the text system and every
        // decoded image -- waits until the hotkey is pressed for the first time.
        // Even though an agent app never displays a menu bar, the main menu is
        // what makes Cmd+C/V/A/Z work inside the search field.
        MainMenu.install()
        FrontmostTracker.shared.start()
        MenuBarController.shared.install()

        let store = ItemStore.shared
        store.onInsert = { PanelController.shared.storeDidInsert($0) }
        store.onTouch = { PanelController.shared.storeDidTouch(id: $0, updatedAt: $1) }
        store.onDelete = { PanelController.shared.storeDidDelete(ids: $0) }
        store.collectOrphansAtLaunch()

        ClipboardMonitor.shared.start()
        registerHotKey()
        askAboutLoginIfNeeded()

        Log.ui("launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The sweep runs on the store queue, so wait for it -- an async call here
        // would usually be killed by the process exiting before it did anything.
        let done = DispatchSemaphore(value: 0)
        ItemStore.shared.sweep { done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Launching an already-running agent app -- `open -a cbm`, or picking it in
    /// Spotlight -- opens the panel. Gives another launcher a way in, and is the
    /// fallback if the hotkey is ever taken by something else.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelController.shared.show()
        return true
    }

    private func registerHotKey() {
        hotKey = HotKey(
            keyCode: HotKeyDefaults.openPanelKeyCode,
            modifiers: HotKeyDefaults.openPanelModifiers
        ) {
            PanelController.shared.toggle()
        }

        guard hotKey == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Could not register \(HotKeyDefaults.openPanelDisplay)"
        alert.informativeText =
            "Another application already owns that shortcut. cbm is running and still "
            + "recording your clipboard — open it from the menu bar icon instead."
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Registering a login item writes persistent system state, so it is asked
    /// for once rather than assumed.
    private func askAboutLoginIfNeeded() {
        guard !Settings.shared.hasAskedAboutLogin, !LoginItem.isEnabled else { return }
        Settings.shared.hasAskedAboutLogin = true

        let alert = NSAlert()
        alert.messageText = "Launch cbm at login?"
        alert.informativeText =
            "A clipboard manager is only useful if it is already running when you copy "
            + "something. You can change this later in Settings."
        alert.addButton(withTitle: "Launch at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            LoginItem.set(true)
        }
    }
}
