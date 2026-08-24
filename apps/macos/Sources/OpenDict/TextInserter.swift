import AppKit
import ApplicationServices

/// Puts the finished text into whatever app has focus.
///
/// Two strategies, in order:
///
/// 1. **Accessibility** — set `kAXSelectedTextAttribute` on the focused element.
///    Clean, leaves the clipboard alone, and preserves undo in well-behaved apps.
///    Its notorious flaw is that it returns `.success` on plenty of elements
///    where nothing is actually inserted, so we verify afterwards rather than
///    trusting the return code.
/// 2. **Clipboard + ⌘V** — works essentially everywhere, including Electron apps
///    and terminals. Costs a clipboard round-trip, which we save and restore.
enum TextInserter {
    enum Method: String {
        case accessibility
        case paste
    }

    /// Insert `text`, returning which method actually worked.
    @MainActor
    static func insert(_ text: String, preferAccessibility: Bool) -> Method {
        guard !text.isEmpty else { return .accessibility }

        if preferAccessibility, insertViaAccessibility(text) {
            return .accessibility
        }
        insertViaPaste(text)
        return .paste
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return false }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.25)

        // Only text-bearing elements. Attempting this on, say, a web area
        // reports success and does nothing.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        guard let role = roleRef as? String,
            role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
        else { return false }

        // Read back the value to confirm the insertion actually landed. A
        // success code is not evidence; a changed document is.
        var beforeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &beforeRef)
        let before = beforeRef as? String

        let status = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard status == .success else { return false }

        var afterRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &afterRef)
        let after = afterRef as? String

        // If we could read the value both times and it did not change, the
        // insertion was a no-op no matter what the status code said.
        if let before, let after, before == after { return false }
        return true
    }

    // MARK: - Clipboard

    private static func insertViaPaste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Preserve whatever the user had. Only string types are restored —
        // faithfully round-tripping arbitrary flavours (promised files, rich
        // content) is not achievable, so we keep the common case correct.
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // The paste is asynchronous in the target app. Restoring immediately
        // races it and pastes the old clipboard instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pasteboard.string(forType: .string) == text else {
                // Something else took the clipboard in the meantime; leave it.
                return
            }
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // 9 = 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
