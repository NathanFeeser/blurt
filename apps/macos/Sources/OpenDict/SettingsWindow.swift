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

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if let window {
            activate(window)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
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
