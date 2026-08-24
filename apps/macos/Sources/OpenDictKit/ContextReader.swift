import AppKit
import ApplicationServices
import OpenDictCore

/// Reads the frontmost app and the text around the caret via the Accessibility
/// API, so the cleanup stage knows where the words are going.
///
/// This is the highest-leverage input to output quality — see the note in
/// `crates/opendict-core/src/context.rs`. It is also the most failure-prone code
/// in the app: many apps expose nothing useful, Electron apps lie, and AX calls
/// against a busy or hung app will block. Everything here is best-effort and
/// must degrade to `AppContext()` rather than throwing or hanging.
enum ContextReader {
    /// AX calls are synchronous IPC into another process. Without a timeout a
    /// hung target app hangs *us*, and the recording indicator sticks on screen.
    private static let timeoutSeconds: Float = 0.25

    /// Call off the main thread. Returns whatever it could gather.
    static func read(includeSelection: Bool) -> AppContext {
        var context = AppContext(
            bundleId: nil,
            appName: nil,
            windowTitle: nil,
            surroundingText: nil,
            selectedText: nil
        )

        let frontmost = NSWorkspace.shared.frontmostApplication
        context.bundleId = frontmost?.bundleIdentifier
        context.appName = frontmost?.localizedName

        guard AXIsProcessTrusted() else { return context }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeoutSeconds)

        guard let focused = copyElement(system, kAXFocusedUIElementAttribute) else {
            return context
        }
        AXUIElementSetMessagingTimeout(focused, timeoutSeconds)

        context.windowTitle = windowTitle(for: focused)

        if let value = copyString(focused, kAXValueAttribute), !value.isEmpty {
            context.surroundingText = value
        }

        if includeSelection, let selection = copyString(focused, kAXSelectedTextAttribute),
            !selection.isEmpty
        {
            context.selectedText = selection
        }

        return context
    }

    private static func windowTitle(for element: AXUIElement) -> String? {
        // Walk up to the window; the focused element itself rarely has a title.
        var current = element
        for _ in 0..<6 {
            if let role = copyString(current, kAXRoleAttribute), role == kAXWindowRole {
                return copyString(current, kAXTitleAttribute)
            }
            guard let parent = copyElement(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value
        else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
