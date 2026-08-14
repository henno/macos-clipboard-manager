import AppKit

/// The status bar item. Without it an agent app has no way to reach Settings or
/// to quit, so it is not optional in practice.
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?

    private init() {}

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "cbm clipboard history")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(entry("Open cbm  \(HotKeyDefaults.openPanelDisplay)", #selector(openPanel)))
        menu.addItem(.separator())
        menu.addItem(entry("Settings…", #selector(openSettings), key: ","))
        menu.addItem(entry("Clear History…", #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(entry("Quit cbm", #selector(quit), key: "q"))

        item.menu = menu
        statusItem = item
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openPanel() {
        PanelController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete all clipboard history?"
        alert.informativeText = "Every stored entry, image and thumbnail will be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Everything")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ItemStore.shared.deleteAll {
            SearchIndex.shared.rebuild(from: [])
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
