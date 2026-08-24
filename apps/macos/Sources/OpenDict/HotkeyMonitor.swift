import AppKit

/// Hold-to-talk on a modifier key.
///
/// Right Option is the default: it is a real key on every Mac keyboard, almost
/// nothing binds it alone, and holding it is a comfortable gesture. Modifier
/// keys are watched through `flagsChanged` rather than `keyDown` because a bare
/// modifier never produces a key event.
///
/// This needs Accessibility permission. Without it the global monitor installs
/// successfully and then silently never fires, which is the single most
/// confusing failure mode in the app — so `AppDelegate` checks the permission
/// explicitly rather than inferring it from silence.
final class HotkeyMonitor {
    enum Key: String, CaseIterable {
        case rightOption
        case leftOption
        case rightCommand
        case fn

        var keyCode: UInt16 {
            switch self {
            case .rightOption: return 61
            case .leftOption: return 58
            case .rightCommand: return 54
            case .fn: return 63
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .rightOption, .leftOption: return .option
            case .rightCommand: return .command
            case .fn: return .function
            }
        }

        var displayName: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .leftOption: return "Left Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .fn: return "Fn / Globe"
            }
        }
    }

    var key: Key = .rightOption

    /// Semantic events. The shell should not need to know about taps, holds, or
    /// timing thresholds — that logic lives here so the same gestures can be
    /// reused by the Windows shell later.
    ///
    /// Gestures:
    ///   * **Hold** the key and speak, release to finish. The default.
    ///   * **Double-tap** to engage hands-free: recording continues with the key
    ///     released, and a single tap ends it. For dictating something long
    ///     without holding a modifier down the whole time.
    ///   * **Escape** while recording aborts without transcribing.
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A double-tap was recognised; recording continues without the key held.
    var onHandsFreeEngaged: (() -> Void)?
    /// A tap too short to be dictation. Throw the audio away silently.
    var onDiscard: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Below this, a press is a tap rather than a hold. Generous enough to
    /// survive a deliberate but quick press, short enough that a real dictation
    /// never trips it.
    private let holdThreshold: TimeInterval = 0.25
    /// Maximum gap between the two taps of a double-tap.
    private let doubleTapWindow: TimeInterval = 0.4

    private enum State {
        case idle
        case holding
        case handsFree
    }

    private var state: State = .idle
    private var pressedAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = 0

    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isRecording: Bool { state != .idle }

    func start() {
        stop()
        // Global fires when another app is focused — the normal case. Local
        // fires when OpenDict itself is focused, which happens during setup.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        state = .idle
    }

    /// Abort from outside the monitor (menu, error path).
    func reset() {
        state = .idle
        lastTapAt = 0
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            // 53 = Escape.
            if event.keyCode == 53, state != .idle {
                state = .idle
                lastTapAt = 0
                onCancel?()
            }
            return
        }

        guard event.type == .flagsChanged, event.keyCode == key.keyCode else { return }

        // `flagsChanged` reports the state after the change, and keyCode tells us
        // which physical key caused it. Both are needed: the flag alone cannot
        // distinguish left Option from right.
        let isDown = event.modifierFlags.contains(key.flag)
        let now = ProcessInfo.processInfo.systemUptime

        if isDown {
            pressedAt = now
            // In hands-free the key is only being tapped to finish; the press
            // itself must not restart anything.
            if state == .idle {
                state = .holding
                onStart?()
            }
            return
        }

        switch state {
        case .idle:
            break

        case .handsFree:
            state = .idle
            lastTapAt = 0
            onEnd?()

        case .holding:
            let heldFor = now - pressedAt
            if heldFor >= holdThreshold {
                state = .idle
                lastTapAt = 0
                onEnd?()
            } else if now - lastTapAt < doubleTapWindow {
                // Second quick tap: keep the recording running, hands free.
                state = .handsFree
                lastTapAt = 0
                onHandsFreeEngaged?()
            } else {
                // A single quick tap. Discard it and remember the time, so the
                // next tap can complete a double-tap.
                state = .idle
                lastTapAt = now
                onDiscard?()
            }
        }
    }
}
