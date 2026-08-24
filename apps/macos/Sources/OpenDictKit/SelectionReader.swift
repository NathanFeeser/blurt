import AppKit
import ApplicationServices

/// Reads the user's current text selection from whatever app has focus.
///
/// Command mode ("make this more formal", "translate this to Japanese") is
/// useless without this, and the Accessibility API alone is not enough: native
/// text views expose `kAXSelectedTextAttribute`, but browsers, Electron apps,
/// and terminals — most of where people actually work — do not.
///
/// So there is a fallback that synthesises ⌘C and reads the pasteboard. That is
/// intrusive enough to be worth doing carefully: it saves and restores the
/// user's clipboard, and it waits for the pasteboard's change count to move
/// rather than sleeping a fixed interval and hoping.
enum SelectionReader {
    enum Source: String {
        case accessibility
        case clipboard
        case none
    }

    struct Result {
        let text: String
        let source: Source
    }

    /// Call off the main thread: both paths block.
    static func read() -> Result {
        if let text = viaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(text: text, source: .accessibility)
        }
        if let text = viaClipboard(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(text: text, source: .clipboard)
        }
        return Result(text: "", source: .none)
    }

    // MARK: - Accessibility

    private static func viaAccessibility() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.25)

        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    // MARK: - Clipboard

    private static func viaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount

        postCommandC()

        // Poll for the copy to land. Apps vary from near-instant to ~200 ms, so
        // waiting on the change count beats guessing a sleep duration: it
        // returns as soon as the data is there and gives up quickly when the
        // selection was empty and nothing was copied at all.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let copied = pasteboard.string(forType: .string)
                restore(saved, to: pasteboard)
                return copied
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        restore(saved, to: pasteboard)
        return nil
    }

    private static func restore(_ saved: String?, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // 8 = 'c'
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
