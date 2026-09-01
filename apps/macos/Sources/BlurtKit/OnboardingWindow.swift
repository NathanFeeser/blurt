import AppKit
import SwiftUI

/// Hosts the first-run flow in a window.
///
/// Separate from `SettingsWindow` rather than a sixth tab in it: this one is
/// modal in spirit, has its own back-and-forward navigation, and is the only
/// window in the app that a brand new user should be looking at.
///
/// Closing it early is allowed and deliberately records nothing — the flow is
/// only marked complete when it finishes, so an abandoned setup comes back on
/// the next launch instead of leaving somebody with a half-configured app and
/// no way back in.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    /// Called when the user finishes the flow, so start-up can carry on with
    /// the permissions it was waiting for.
    var onFinish: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if let window {
            activate(window)
            return
        }

        // Built fresh each time, so reopening from the menu resumes at whatever
        // is missing now rather than wherever the last visit stopped.
        let flow = OnboardingModel(environment: .live(model: model))
        let hosting = NSHostingController(
            rootView: OnboardingView(
                onboarding: flow,
                model: model,
                onFinish: { [weak self] in self?.finish() }))

        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up Blurt"
        // No .miniaturizable: a setup window minimised into the Dock by an app
        // with no Dock icon is a window you cannot get back.
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        activate(window)
    }

    private func finish() {
        onFinish?()
        window?.close()
    }

    private func activate(_ window: NSWindow) {
        // .regular so the window can take keyboard focus — an .accessory app
        // cannot, which would leave every field in the flow unable to accept a
        // single keystroke.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Dropped rather than reused: the next `show` builds a flow that starts
        // from current state.
        window = nil
    }
}
