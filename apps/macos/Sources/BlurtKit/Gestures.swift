import Foundation

/// Recognises the dictation gestures from raw key up/down events.
///
/// Deliberately free of AppKit: given a timestamp and whether the key went down
/// or up, it decides whether that was a hold, a tap, or the second half of a
/// double-tap. `HotkeyMonitor` is the thin adapter that feeds it NSEvents.
///
/// Splitting it out is what makes the thresholds testable. They were tuned by
/// hand against a real keyboard and the two constants pull against each other —
/// a wider double-tap window makes hands-free easier to trigger deliberately and
/// easier to trigger by accident between two quick dictations.
struct GestureRecognizer {
    enum Event: Equatable {
        /// Begin recording.
        case start
        /// Finish and transcribe.
        case end
        /// Double-tap recognised; keep recording with the key released.
        case handsFreeEngaged
        /// Too short to be dictation. Throw the audio away silently.
        case discard
        /// Abort without transcribing.
        case cancel
    }

    enum State: Equatable {
        case idle
        case holding
        case handsFree
    }

    /// Below this, a press is a tap rather than a hold. Generous enough to
    /// survive a deliberate but quick press, short enough that a real dictation
    /// never trips it.
    var holdThreshold: TimeInterval = 0.25
    /// Maximum gap between the two taps of a double-tap.
    var doubleTapWindow: TimeInterval = 0.4

    private(set) var state: State = .idle
    private var pressedAt: TimeInterval = 0
    /// "No tap has happened yet" — deliberately not 0.
    ///
    /// With 0, the very first tap satisfies `now - lastTapAt < doubleTapWindow`
    /// whenever `now` is small, and is treated as the *second* half of a
    /// double-tap. In production `now` is the system uptime, so this only
    /// misfires within the first 400 ms after boot — but it is wrong, and it
    /// made the recogniser untestable with sensible timestamps.
    private var lastTapAt: TimeInterval = -.infinity

    var isRecording: Bool { state != .idle }

    mutating func keyDown(at now: TimeInterval) -> Event? {
        pressedAt = now
        // In hands-free the key is only being tapped to finish; the press itself
        // must not restart anything.
        guard state == .idle else { return nil }
        state = .holding
        return .start
    }

    mutating func keyUp(at now: TimeInterval) -> Event? {
        switch state {
        case .idle:
            return nil

        case .handsFree:
            state = .idle
            lastTapAt = -.infinity
            return .end

        case .holding:
            let heldFor = now - pressedAt
            if heldFor >= holdThreshold {
                state = .idle
                lastTapAt = -.infinity
                return .end
            }
            if now - lastTapAt < doubleTapWindow {
                // Second quick tap: keep recording, hands free.
                state = .handsFree
                lastTapAt = -.infinity
                return .handsFreeEngaged
            }
            // A single quick tap. Discard it and remember when, so the next tap
            // can complete a double-tap.
            state = .idle
            lastTapAt = now
            return .discard
        }
    }

    mutating func escape() -> Event? {
        guard state != .idle else { return nil }
        state = .idle
        lastTapAt = -.infinity
        return .cancel
    }

    mutating func reset() {
        state = .idle
        lastTapAt = -.infinity
    }
}
