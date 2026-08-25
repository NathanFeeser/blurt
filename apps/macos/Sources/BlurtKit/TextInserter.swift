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

    // MARK: - Undo

    /// What was put where, so it can be taken back out.
    struct Insertion: Equatable {
        let text: String
        /// The app it went into. Undoing into a *different* app is the failure
        /// mode that matters, so this is checked before anything is sent.
        let bundleId: String?
        let at: Date
        let entryId: Int64?
    }

    /// How to take back an insertion, or why we won't.
    enum UndoPlan: Equatable {
        /// The focused field still ends with exactly what we inserted, so the
        /// suffix can be removed precisely.
        case removeSuffix
        /// We can't verify the text, but we're still in the app we inserted
        /// into, so ⌘Z is the best available guess.
        case sendUndoKeystroke
        case refuse(String)
    }

    /// Long enough to cover "wait, no" plus reading what appeared; short enough
    /// that a stale insertion from an hour ago is never acted on.
    static let undoWindow: TimeInterval = 120

    /// Decide what undo should do. Pure, and separated from the AppKit calls
    /// because this is the rule that keeps ⌘Z out of the wrong window — a
    /// mistake that destroys work the user did themselves.
    ///
    /// `focusedText` is the current value of the focused field, or nil when it
    /// could not be read (which is common and not itself suspicious).
    static func undoPlan(
        for insertion: Insertion,
        frontmostBundleId: String?,
        focusedText: String?,
        now: Date = Date()
    ) -> UndoPlan {
        guard !insertion.text.isEmpty else {
            return .refuse("Nothing to undo")
        }
        guard now.timeIntervalSince(insertion.at) <= undoWindow else {
            return .refuse("Too long ago to undo")
        }
        // A different app means the keystroke would land somewhere it was never
        // invited. Refuse rather than guess.
        if let inserted = insertion.bundleId, let frontmost = frontmostBundleId,
            inserted != frontmost
        {
            return .refuse("Switch back to the app you dictated into")
        }
        guard let focusedText else {
            // Unreadable field: browsers, Electron, terminals. The app check
            // above already passed, so ⌘Z is reasonable.
            return .sendUndoKeystroke
        }
        if focusedText.hasSuffix(insertion.text) {
            return .removeSuffix
        }
        if focusedText.contains(insertion.text) {
            // Still there, but something follows it. Removing a middle range
            // would need the caret to be where we think it is; ⌘Z lets the app
            // resolve that with its own undo stack.
            return .sendUndoKeystroke
        }
        return .refuse("That text is no longer here")
    }

    enum UndoOutcome: Equatable {
        case removed
        case sentUndoKeystroke
        case refused(String)
    }

    /// Take back the last insertion.
    ///
    /// The caller supplies `frontmostBundleId` rather than us asking the
    /// workspace: undo is triggered from the menu bar, and while our own menu
    /// is up the frontmost app is Blurt — which would refuse every undo. The
    /// delegate already tracks the last app that was really in front.
    @MainActor
    static func undo(
        _ insertion: Insertion, frontmostBundleId frontmost: String?, now: Date = Date()
    ) -> UndoOutcome {
        let focused = focusedTextElement()
        let currentText = focused.flatMap { readValue($0) }

        switch undoPlan(
            for: insertion, frontmostBundleId: frontmost, focusedText: currentText, now: now)
        {
        case .refuse(let why):
            return .refused(why)
        case .sendUndoKeystroke:
            postCommandZ()
            return .sentUndoKeystroke
        case .removeSuffix:
            guard let focused, let currentText,
                setValue(focused, String(currentText.dropLast(insertion.text.count)))
            else {
                // The field refused the write — read-only AX values are common.
                postCommandZ()
                return .sentUndoKeystroke
            }
            return .removed
        }
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard let focused = focusedTextElement() else { return false }

        // Read back the value to confirm the insertion actually landed. A
        // success code is not evidence; a changed document is.
        let before = readValue(focused)

        let status = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard status == .success else { return false }

        let after = readValue(focused)

        // If we could read the value both times and it did not change, the
        // insertion was a no-op no matter what the status code said.
        if let before, let after, before == after { return false }
        return true
    }

    /// The focused element, but only if it is one that actually holds text.
    /// Attempting an insertion on, say, a web area reports success and does
    /// nothing.
    private static func focusedTextElement() -> AXUIElement? {
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

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        guard let role = roleRef as? String,
            role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
        else { return nil }
        return focused
    }

    private static func readValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
        return ref as? String
    }

    /// Write a whole field value back, verifying it took. Plenty of elements
    /// report success on a value they never applied.
    private static func setValue(_ element: AXUIElement, _ text: String) -> Bool {
        guard
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
                == .success
        else { return false }
        return readValue(element) == text
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

    private static func postCommandZ() {
        // 6 = 'z'
        postCommandKey(6)
    }

    private static func postCommandV() {
        // 9 = 'v'
        postCommandKey(9)
    }

    private static func postCommandKey(_ virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
