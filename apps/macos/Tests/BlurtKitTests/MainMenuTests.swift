import AppKit
import Testing

@testable import BlurtKit

/// A menu-bar app has no menu bar of its own until it makes one, and the cost
/// of forgetting is that every text field in the app silently ignores ⌘V while
/// right-click → Paste keeps working. Reported from real use, pasting an API key.
@Suite("Main menu")
@MainActor
struct MainMenuTests {

    private func editMenu() -> NSMenu? {
        MainMenu.make().items.compactMap(\.submenu).first { $0.title == "Edit" }
    }

    @Test("The Edit menu carries the standard editing shortcuts")
    func editMenuHasTheStandardShortcuts() {
        let items = editMenu()?.items ?? []
        let shortcuts = Dictionary(
            uniqueKeysWithValues: items.filter { !$0.keyEquivalent.isEmpty }
                .map { ($0.title, $0.keyEquivalent) })

        #expect(shortcuts["Paste"] == "v")
        #expect(shortcuts["Copy"] == "c")
        #expect(shortcuts["Cut"] == "x")
        #expect(shortcuts["Select All"] == "a")
        #expect(shortcuts["Undo"] == "z")
    }

    @Test("Editing items go through the responder chain")
    func editingItemsHaveNoTarget() {
        // A target here would send Paste somewhere fixed instead of to whichever
        // text field is focused, which is the whole mechanism.
        let paste = editMenu()?.items.first { $0.title == "Paste" }
        #expect(paste?.target == nil)
    }

    @Test("Redo is shift-command-Z, not command-Z")
    func redoCarriesShift() {
        let redo = editMenu()?.items.first { $0.title == "Redo" }
        #expect(redo?.keyEquivalentModifierMask == [.command, .shift])
    }
}
