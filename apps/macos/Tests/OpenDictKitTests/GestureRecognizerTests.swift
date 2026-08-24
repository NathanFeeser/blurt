import Foundation
import Testing

@testable import OpenDictKit

/// The gesture thresholds were tuned by hand against a real keyboard, and the
/// two constants pull against each other: a wider double-tap window makes
/// hands-free easier to trigger deliberately *and* easier to trigger by accident
/// between two quick consecutive dictations. These pin down both directions.
@Suite("Gesture recognition")
struct GestureRecognizerTests {

    @Test("Holding the key records and finishes on release")
    func holdToTalk() {
        var g = GestureRecognizer()
        #expect(g.keyDown(at: 0) == .start)
        #expect(g.isRecording)
        #expect(g.keyUp(at: 1.5) == .end)
        #expect(!g.isRecording)
    }

    @Test("A press just over the hold threshold is a real dictation")
    func shortHoldStillCounts() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        #expect(g.keyUp(at: 0.26) == .end)
    }

    @Test("A single quick tap is discarded, not transcribed")
    func singleTapDiscards() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        #expect(g.keyUp(at: 0.1) == .discard)
        #expect(!g.isRecording)
    }

    @Test("Double-tap engages hands-free and keeps recording")
    func doubleTapEngagesHandsFree() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        #expect(g.keyUp(at: 0.08) == .discard)
        _ = g.keyDown(at: 0.2)
        #expect(g.keyUp(at: 0.28) == .handsFreeEngaged)
        #expect(g.isRecording, "hands-free must keep recording with the key released")
    }

    @Test("A tap ends hands-free")
    func tapEndsHandsFree() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.08)
        _ = g.keyDown(at: 0.2)
        _ = g.keyUp(at: 0.28)

        // Pressing again during hands-free must not restart anything.
        #expect(g.keyDown(at: 5.0) == nil)
        #expect(g.keyUp(at: 5.05) == .end)
        #expect(!g.isRecording)
    }

    @Test("Two back-to-back dictations do not become hands-free")
    func consecutiveDictationsDoNotTriggerHandsFree() {
        // The reported real-world case: three dictations inside five seconds.
        // Each is a hold, so no tap timing is recorded and no double-tap can form.
        var g = GestureRecognizer()
        for start in [0.0, 1.2, 2.4] {
            #expect(g.keyDown(at: start) == .start)
            #expect(g.keyUp(at: start + 0.9) == .end, "each dictation must finish normally")
        }
    }

    @Test("Two taps far apart are two discards, not a double-tap")
    func slowTapsAreNotADoubleTap() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        #expect(g.keyUp(at: 0.08) == .discard)
        _ = g.keyDown(at: 2.0)
        #expect(g.keyUp(at: 2.08) == .discard, "beyond the window it is just another tap")
    }

    @Test("Escape cancels a hold and hands-free alike")
    func escapeCancels() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        #expect(g.escape() == .cancel)
        #expect(!g.isRecording)

        _ = g.keyDown(at: 1.0)
        _ = g.keyUp(at: 1.08)
        _ = g.keyDown(at: 1.2)
        _ = g.keyUp(at: 1.28)
        #expect(g.isRecording)
        #expect(g.escape() == .cancel)
        #expect(!g.isRecording)
    }

    @Test("Escape while idle does nothing")
    func escapeWhileIdleIsInert() {
        var g = GestureRecognizer()
        #expect(g.escape() == nil)
    }

    @Test("A discarded tap does not leave the recogniser recording")
    func discardLeavesCleanState() {
        var g = GestureRecognizer()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.05)
        #expect(g.state == .idle)
        // And the next hold works normally.
        #expect(g.keyDown(at: 3.0) == .start)
        #expect(g.keyUp(at: 4.0) == .end)
    }
}
