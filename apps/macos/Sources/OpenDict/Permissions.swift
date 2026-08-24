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
