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

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Escape while recording aborts without transcribing.
    var onCancel: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

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
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            // 53 = Escape.
            if event.keyCode == 53, isDown {
                isDown = false
                onCancel?()
            }
            return
        }

        guard event.type == .flagsChanged, event.keyCode == key.keyCode else { return }

        // `flagsChanged` reports the state after the change, and keyCode tells us
        // which physical key caused it. Both are needed: the flag alone cannot
        // distinguish left Option from right.
        let nowDown = event.modifierFlags.contains(key.flag)

        if nowDown, !isDown {
            isDown = true
            onPress?()
        } else if !nowDown, isDown {
            isDown = false
            onRelease?()
        }
    }
}
