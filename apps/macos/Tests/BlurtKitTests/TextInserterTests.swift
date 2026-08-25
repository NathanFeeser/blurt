import Foundation
import Testing

@testable import BlurtKit

/// The rules that decide whether undo is safe to attempt.
///
/// Worth testing directly: the failure this guards against — sending ⌘Z into
/// the wrong window — destroys work the user did themselves, and it is not
/// something a manual pass would reliably reproduce.
@Suite("Undo eligibility")
struct UndoPlanTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func insertion(
        _ text: String = "the quick brown fox",
        bundleId: String? = "com.apple.Notes",
        secondsAgo: TimeInterval = 2
    ) -> TextInserter.Insertion {
        TextInserter.Insertion(
            text: text,
            bundleId: bundleId,
            at: now.addingTimeInterval(-secondsAgo),
            entryId: 1
        )
    }

    @Test("Removes the exact text when the field still ends with it")
    func removesExactSuffix() {
        let plan = TextInserter.undoPlan(
            for: insertion(),
            frontmostBundleId: "com.apple.Notes",
            focusedText: "Meeting notes: the quick brown fox",
            now: now)
        #expect(plan == .removeSuffix)
    }

    @Test("Falls back to ⌘Z when the field cannot be read")
    func unreadableFieldFallsBack() {
        // Browsers, Electron, terminals — the paste path exists precisely
        // because their fields are opaque to Accessibility.
        let plan = TextInserter.undoPlan(
            for: insertion(),
            frontmostBundleId: "com.apple.Notes",
            focusedText: nil,
            now: now)
        #expect(plan == .sendUndoKeystroke)
    }

    @Test("Falls back to ⌘Z when the user typed after the insertion")
    func typingAfterwardsFallsBack() {
        let plan = TextInserter.undoPlan(
            for: insertion(),
            frontmostBundleId: "com.apple.Notes",
            focusedText: "the quick brown fox jumped over",
            now: now)
        #expect(plan == .sendUndoKeystroke)
    }

    @Test("Refuses once the user has switched apps")
    func refusesInADifferentApp() {
        // The one that matters: ⌘Z here would undo whatever the user last did
        // in Xcode, which Blurt has no business touching.
        let plan = TextInserter.undoPlan(
            for: insertion(),
            frontmostBundleId: "com.apple.dt.Xcode",
            focusedText: "some unrelated code",
            now: now)
        #expect(plan == .refuse("Switch back to the app you dictated into"))
    }

    @Test("Refuses when the text is no longer in the field")
    func refusesWhenTheTextIsGone() {
        let plan = TextInserter.undoPlan(
            for: insertion(),
            frontmostBundleId: "com.apple.Notes",
            focusedText: "something else entirely",
            now: now)
        #expect(plan == .refuse("That text is no longer here"))
    }

    @Test("Refuses a stale insertion")
    func refusesStaleInsertions() {
        let plan = TextInserter.undoPlan(
            for: insertion(secondsAgo: TextInserter.undoWindow + 1),
            frontmostBundleId: "com.apple.Notes",
            focusedText: "the quick brown fox",
            now: now)
        #expect(plan == .refuse("Too long ago to undo"))
    }

    @Test("An unknown frontmost app does not block undo")
    func unknownFrontmostStillWorks() {
        // Not every process reports a bundle id. Refusing on a missing value
        // would make undo unavailable in exactly the apps hardest to insert
        // into, which is backwards.
        let plan = TextInserter.undoPlan(
            for: insertion(),
            frontmostBundleId: nil,
            focusedText: "the quick brown fox",
            now: now)
        #expect(plan == .removeSuffix)
    }

    @Test("Nothing to undo is refused rather than sending a stray keystroke")
    func emptyInsertionRefused() {
        let plan = TextInserter.undoPlan(
            for: insertion(""),
            frontmostBundleId: "com.apple.Notes",
            focusedText: "anything",
            now: now)
        #expect(plan == .refuse("Nothing to undo"))
    }
}

@Suite("Menu previews")
@MainActor
struct MenuPreviewTests {
    @Test("Collapses newlines so a multi-line dictation stays one row")
    func collapsesNewlines() {
        #expect(AppDelegate.menuPreview("first line\nsecond line") == "first line second line")
    }

    @Test("Truncates long text with an ellipsis")
    func truncatesLongText() {
        let preview = AppDelegate.menuPreview(String(repeating: "a", count: 100), limit: 10)
        #expect(preview == String(repeating: "a", count: 10) + "…")
    }

    @Test("Leaves short text alone")
    func leavesShortTextAlone() {
        #expect(AppDelegate.menuPreview("ship it") == "ship it")
    }
}
