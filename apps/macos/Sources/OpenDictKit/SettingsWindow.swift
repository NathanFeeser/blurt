import AppKit
import SwiftUI

/// Hosts the settings UI in a normal window.
///
/// A menu-bar app has no windows by default, so this also has to flip the
/// activation policy: an `.accessory` app cannot take focus, which would leave
/// the settings window visible but unable to accept a single keystroke.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    /// Which tab is showing. Held out here rather than as view state because
    /// the window is created once and reused: a menu item that opens History
    /// has to be able to switch tabs on a window that already exists.
    private let navigation = SettingsNavigation()

    init(model: AppModel) {
        self.model = model
    }

    func show(tab: SettingsTab = .general) {
        navigation.tab = tab

        if let window {
            activate(window)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(model: model, navigation: navigation))
        let window = NSWindow(contentViewController: hosting)
        window.title = "OpenDict Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        activate(window)
    }

    private func activate(_ window: NSWindow) {
        // .regular lets the window take keyboard focus. Reverted on close so the
        // app goes back to being menu-bar-only with no Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
