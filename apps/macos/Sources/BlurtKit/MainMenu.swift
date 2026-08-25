import AppKit

/// The application menu bar.
///
/// A menu-bar-only app has no windows and no storyboard, so it is tempting to
/// skip this entirely — nothing visibly breaks. What breaks invisibly is every
/// standard editing shortcut: AppKit dispatches ⌘V, ⌘C, ⌘X, ⌘A, and ⌘Z through
/// the Edit menu's key equivalents, so with no main menu they reach nothing at
/// all. Text fields then accept typing and right-click → Paste while silently
/// ignoring ⌘V, which reads as a broken text field rather than a missing menu.
///
/// The items deliberately have no target. A nil target sends the action down
/// the responder chain, which is what lands it on whichever text field is
/// focused; wiring them to anything specific would break that.
enum MainMenu {

    static func install(on app: NSApplication) {
        app.mainMenu = make()
    }

    /// Built separately from installing it so the shortcuts can be tested.
    static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = appMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editMenu()
        main.addItem(editItem)

        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Blurt")
        menu.addItem(
            withTitle: "About Blurt",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Blurt",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Blurt",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        // Undo and redo live on the responder chain's undo manager rather than
        // on any class we can take a #selector to.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(
            title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}
