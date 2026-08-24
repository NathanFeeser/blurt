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

    /// The gesture state machine. Lives in `GestureRecognizer` so the
    /// thresholds can be tested without synthesising NSEvents.
    private var recognizer = GestureRecognizer()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isRecording: Bool { recognizer.isRecording }

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
        recognizer.reset()
    }

    /// Abort from outside the monitor (menu, error path).
    func reset() {
        recognizer.reset()
    }

    private func handle(_ event: NSEvent) {
        // Uptime rather than wall-clock: it cannot jump backwards across a
        // clock change mid-gesture.
        let now = ProcessInfo.processInfo.systemUptime

        if event.type == .keyDown {
            // 53 = Escape.
            if event.keyCode == 53 {
                emit(recognizer.escape())
            }
            return
        }

        guard event.type == .flagsChanged, event.keyCode == key.keyCode else { return }

        // `flagsChanged` reports the state after the change, and keyCode tells us
        // which physical key caused it. Both are needed: the flag alone cannot
        // distinguish left Option from right.
        if event.modifierFlags.contains(key.flag) {
            emit(recognizer.keyDown(at: now))
        } else {
            emit(recognizer.keyUp(at: now))
        }
    }

    private func emit(_ event: GestureRecognizer.Event?) {
        switch event {
        case .start: onStart?()
        case .end: onEnd?()
        case .handsFreeEngaged: onHandsFreeEngaged?()
        case .discard: onDiscard?()
        case .cancel: onCancel?()
        case nil: break
        }
    }
}
