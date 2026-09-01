import AVFoundation
import AppKit
import ApplicationServices

/// The two permissions this app cannot work without, and honest reporting of
/// which one is missing.
///
/// Accessibility is the scary one: users are being asked to let an app read and
/// type into every other app. The onboarding cost of explaining that clearly is
/// far lower than the support cost of a silent no-op.
enum Permissions {
    static func statusDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Distinct from "not granted": macOS never re-prompts after a refusal, so
    /// a denied state has to send the user to System Settings rather than
    /// offering a button that would do nothing.
    static func microphoneDenied() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    static func requestMicrophone() async -> Bool {
        if microphoneGranted() { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// `CGEvent.post` and the AXUIElement APIs sit behind different TCC services
    /// (kTCCServicePostEvent vs kTCCServiceAccessibility) even though System
    /// Settings shows them under one "Accessibility" switch. Checking the AX one
    /// is the closest thing to a reliable signal for both.
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts once. macOS will not re-prompt for the same binary, so the menu
    /// also offers a direct link to the settings pane.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // The SDK exports kAXTrustedCheckOptionPrompt as a mutable global, which
        // Swift 6 rejects as shared mutable state. Its value is a documented
        // constant, so use the literal.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Quit and reopen this app.
    ///
    /// macOS decides whether a process is a trusted accessibility client when
    /// the process starts, and granting the permission to an app that is
    /// already running does not reliably reach it. Without a way to relaunch,
    /// setup dead-ends: the switch in System Settings is visibly on, the app
    /// still reports no access, and nothing the user does from that screen can
    /// change it.
    ///
    /// The helper waits for this process to actually exit before reopening, so
    /// two copies never overlap and fight over the same hotkey.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"\(path)\"",
        ]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
