import Foundation

/// The first-run flow, as a state machine with no UI in it.
///
/// Setup is the part of this app most likely to fail silently. Accessibility in
/// particular can be skipped, at which point the hotkey installs successfully
/// and then never fires — the single most confusing failure Blurt has. So the
/// flow refuses to advance past a step until the thing that step is asking for
/// is actually true, and it checks by *observing system state* rather than by
/// trusting a Continue button.
///
/// Everything the flow needs to know about the outside world arrives through
/// `Environment`, which is what makes the ordering, the auto-advance, and the
/// resume-where-you-left-off behaviour testable without touching TCC.
@MainActor
final class OnboardingModel: ObservableObject {

    /// Bumped when the flow changes enough that returning users should see it
    /// again. Stored per-user, so a redesign can re-run setup without also
    /// re-running it for everyone on every launch.
    static let currentVersion = 1

    enum Step: Int, CaseIterable, Comparable {
        /// What this app is, and what it is about to ask for. No prompts here:
        /// a permission dialog before any explanation is how you get denied.
        case welcome
        /// A hosted key, or an on-device model. Either satisfies the step.
        case transcription
        case microphone
        case accessibility
        /// Which input device, with a live level meter. Not a permission, but
        /// the failure it prevents is worse than one — see docs/DECISIONS.md on
        /// Bluetooth hands-free mode.
        case inputDevice
        /// Hold the key and watch your words land in a text field we own.
        case firstDictation

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// System state the flow reacts to. Injected so tests can drive it.
    ///
    /// Main-actor isolated because every one of these reads touches AppKit or
    /// TCC, and because `live` is a shared static that Swift 6 will not let
    /// escape an actor otherwise.
    @MainActor
    struct Environment {
        var microphoneGranted: () -> Bool
        var accessibilityGranted: () -> Bool
        /// A usable transcription path exists: a stored key, or a downloaded
        /// on-device model.
        var transcriptionConfigured: () -> Bool
        /// A successful dictation has been completed inside the flow.
        var didDictate: () -> Bool

        // Reads TCC state, which is main-actor work; the enclosing class is
        // already @MainActor but a nested type does not inherit that.
        //
        // A function of the model rather than a static constant: whether
        // transcription is configured is a question only `AppModel` can answer,
        // and it changes while the flow is on screen.
        @MainActor
        static func live(model: AppModel) -> Environment {
            Environment(
                microphoneGranted: { Permissions.microphoneGranted() },
                accessibilityGranted: { Permissions.accessibilityGranted() },
                transcriptionConfigured: { model.isTranscriptionConfigured },
                // Always false: a dictation that happened last week is not the
                // one this step is asking for. The flow's own
                // `dictationSucceeded` is what the last step sets, and it is
                // deliberately not persisted.
                didDictate: { false }
            )
        }
    }

    @Published private(set) var step: Step = .welcome
    /// Set by the first-dictation step when words actually arrive.
    @Published var dictationSucceeded = false

    private let environment: Environment

    init(environment: Environment, startAt: Step? = nil) {
        self.environment = environment
        self.step = startAt ?? Self.firstUnsatisfiedStep(in: environment)
    }

    // MARK: - What each step is waiting for

    /// Whether a step's requirement is already met.
    ///
    /// `welcome` is never "satisfied" in the sense the others are — it is an
    /// explanation, so it is gated on the user having read it rather than on
    /// any system state. It is skipped on resume, not on first run.
    func isSatisfied(_ step: Step) -> Bool {
        switch step {
        case .welcome: return false
        case .transcription: return environment.transcriptionConfigured()
        case .microphone: return environment.microphoneGranted()
        case .accessibility: return environment.accessibilityGranted()
        // Always true: a device is always selected. The step exists to make
        // the user look at which one, so it is in `alwaysShown` rather than
        // being something that can be satisfied away.
        case .inputDevice: return true
        case .firstDictation: return dictationSucceeded || environment.didDictate()
        }
    }

    /// Whether the user may move on. Every step that asks for something blocks
    /// until it gets it — there is no version of this app that works without
    /// both permissions and a transcription path, so offering "skip" here would
    /// only move the failure somewhere less explicable.
    var canAdvance: Bool {
        switch step {
        case .welcome, .inputDevice: return true
        default: return isSatisfied(step)
        }
    }

    /// Steps whose requirement, once granted, should carry the user forward on
    /// its own. Watching the screen advance the instant you flip a switch in
    /// System Settings is the difference between a flow that feels alive and one
    /// that feels like a form.
    ///
    /// Only the two permissions, because they are the only steps whose
    /// requirement is met somewhere else. Transcription is configured right here
    /// — and a screen that leaves the moment you pick an option is a screen you
    /// cannot read. Selecting "On this Mac" with a model already downloaded
    /// satisfies the step instantly, so this used to make that option
    /// impossible to even look at.
    private var autoAdvances: Bool {
        switch step {
        case .microphone, .accessibility: return true
        case .welcome, .transcription, .inputDevice, .firstDictation: return false
        }
    }

    /// Set by `back`, cleared by `advance`.
    ///
    /// Auto-advance exists to carry somebody forward when the thing they just
    /// granted lands. It has no business overruling somebody who deliberately
    /// walked back to a screen: without this, Back onto an already-satisfied
    /// step bounces straight forward again on the next tick, which is a flow
    /// you cannot navigate backwards at all.
    private var wentBack = false

    // MARK: - Movement

    /// Called on a timer while the flow is on screen, and after returning from
    /// System Settings. Advances if the current step got what it was waiting for.
    func refresh() {
        guard !wentBack, autoAdvances, isSatisfied(step) else { return }
        advance()
    }

    /// Steps that are shown every time regardless of state.
    ///
    /// The other steps ask for something and can be skipped once they have it.
    /// These three do not: `welcome` explains, `inputDevice` confirms a choice
    /// that is always technically made but frequently wrong, and
    /// `firstDictation` is the entire point — a setup flow that ends without the
    /// user seeing it work has not verified anything.
    private static let alwaysShown: Set<Step> = [.welcome, .inputDevice, .firstDictation]

    func advance() {
        guard canAdvance else { return }
        // Moving forward on purpose ends the reprieve: from here on the flow
        // may carry them again.
        wentBack = false
        guard let next = Step(rawValue: step.rawValue + 1) else {
            complete()
            return
        }
        // Skip anything already true. Re-asking for a permission the user
        // granted last week reads as an app that is not paying attention.
        var candidate = next
        while !Self.alwaysShown.contains(candidate), isSatisfied(candidate),
            let after = Step(rawValue: candidate.rawValue + 1)
        {
            candidate = after
        }
        step = candidate
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        wentBack = true
        step = previous
    }

    var isFinished: Bool { Settings.onboardingCompletedVersion >= Self.currentVersion }

    func complete() {
        Settings.onboardingCompletedVersion = Self.currentVersion
    }

    // MARK: - Deciding whether to show the flow at all

    /// Where a fresh flow should open. First run starts at the beginning; a
    /// returning user lands on whatever is actually missing.
    static func firstUnsatisfiedStep(in environment: Environment) -> Step {
        guard Settings.onboardingCompletedVersion >= currentVersion else { return .welcome }
        let model = OnboardingModel(environment: environment, startAt: .welcome)
        for step in Step.allCases where step != .welcome && step != .firstDictation {
            if !model.isSatisfied(step) { return step }
        }
        return .welcome
    }

    /// Whether to put the flow on screen at launch.
    ///
    /// True on first run, and true again if a permission was revoked later —
    /// the alternative is an app that has quietly stopped working and says
    /// nothing about it, which is the failure this whole flow exists to prevent.
    static func shouldPresentAtLaunch(in environment: Environment) -> Bool {
        if Settings.onboardingCompletedVersion < currentVersion { return true }
        return !environment.microphoneGranted()
            || !environment.accessibilityGranted()
            || !environment.transcriptionConfigured()
    }
}
