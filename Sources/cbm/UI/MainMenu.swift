import AppKit

/// An agent app shows no menu bar, which makes it easy to assume it does not
/// need a menu. It does: AppKit resolves Cmd+C, Cmd+V, Cmd+A and friends through
/// the main menu's key equivalents, so without an Edit menu those keys do
/// nothing at all inside the search field.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = appMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        editItem.submenu = editMenu()

        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "cbm")
        menu.addItem(item("Settings…", #selector(SettingsWindowController.show), ",",
                          target: SettingsWindowController.shared))
        menu.addItem(.separator())
        menu.addItem(item("Hide cbm", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(.separator())
        menu.addItem(item("Quit cbm", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))

        let redo = item("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// A nil target sends the action down the responder chain, which is what
    /// puts these commands in the hands of whatever text field has focus.
    private static func item(
        _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
