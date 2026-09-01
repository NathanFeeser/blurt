import Foundation
import Testing

@testable import BlurtKit

/// A mutable stand-in for the system: permissions and configuration the flow
/// reacts to, flipped by hand the way a user flipping switches in System
/// Settings would.
@MainActor
final class FakeSystem {
    var mic = false
    var accessibility = false
    var transcription = false
    var dictated = false

    var environment: OnboardingModel.Environment {
        OnboardingModel.Environment(
            microphoneGranted: { [weak self] in self?.mic ?? false },
            accessibilityGranted: { [weak self] in self?.accessibility ?? false },
            transcriptionConfigured: { [weak self] in self?.transcription ?? false },
            didDictate: { [weak self] in self?.dictated ?? false }
        )
    }
}

/// Isolated defaults, so a test never reads or writes the real user's setup
/// state. Same pattern as `makeModel` in AppModelTests.
@MainActor
func isolateSettings(_ name: String = UUID().uuidString) {
    let suite = UserDefaults(suiteName: "blurt.tests.\(name)")!
    suite.removePersistentDomain(forName: "blurt.tests.\(name)")
    Settings.defaults = suite
    Settings.registerDefaults()
}

@Suite("Onboarding flow")
@MainActor
struct OnboardingFlowTests {

    @Test("First run starts at the beginning")
    func firstRunStartsAtWelcome() {
        isolateSettings()
        let system = FakeSystem()
        let model = OnboardingModel(environment: system.environment)
        #expect(model.step == .welcome)
    }

    @Test("A step that asks for a permission will not advance without it")
    func permissionStepsBlock() {
        isolateSettings()
        let system = FakeSystem()
        let model = OnboardingModel(environment: system.environment, startAt: .microphone)

        #expect(!model.canAdvance)
        model.advance()
        #expect(model.step == .microphone)

        system.mic = true
        #expect(model.canAdvance)
        model.advance()
        #expect(model.step == .accessibility)
    }

    @Test("Granting a permission carries the user forward without a click")
    func grantingAutoAdvances() {
        isolateSettings()
        let system = FakeSystem()
        let model = OnboardingModel(environment: system.environment, startAt: .accessibility)

        model.refresh()
        #expect(model.step == .accessibility)

        // The user flips the switch in System Settings and comes back.
        system.accessibility = true
        model.refresh()
        #expect(model.step == .inputDevice)
    }

    @Test("The explanation screen never auto-advances past itself")
    func welcomeWaitsForTheUser() {
        isolateSettings()
        let system = FakeSystem()
        system.mic = true
        system.accessibility = true
        system.transcription = true

        let model = OnboardingModel(environment: system.environment, startAt: .welcome)
        model.refresh()
        #expect(model.step == .welcome)
    }

    @Test("Permissions already granted are not asked for again")
    func satisfiedStepsAreSkipped() {
        isolateSettings()
        let system = FakeSystem()
        system.transcription = true
        system.mic = true
        system.accessibility = true

        let model = OnboardingModel(environment: system.environment, startAt: .welcome)
        model.advance()
        #expect(model.step == .inputDevice)
    }

    @Test("The first dictation is never skipped, even when everything else is done")
    func firstDictationAlwaysRuns() {
        isolateSettings()
        let system = FakeSystem()
        system.transcription = true
        system.mic = true
        system.accessibility = true
        system.dictated = true

        let model = OnboardingModel(environment: system.environment, startAt: .inputDevice)
        model.advance()
        #expect(model.step == .firstDictation)
    }

    @Test("Finishing the last step records completion")
    func completingRecordsVersion() {
        isolateSettings()
        let system = FakeSystem()
        let model = OnboardingModel(environment: system.environment, startAt: .firstDictation)

        model.dictationSucceeded = true
        model.advance()
        #expect(Settings.onboardingCompletedVersion == OnboardingModel.currentVersion)
        #expect(model.isFinished)
    }

    @Test("Going back stops at the first screen")
    func backStopsAtWelcome() {
        isolateSettings()
        let system = FakeSystem()
        let model = OnboardingModel(environment: system.environment, startAt: .welcome)
        model.back()
        #expect(model.step == .welcome)
    }
}

@Suite("Onboarding presentation")
@MainActor
struct OnboardingPresentationTests {

    @Test("Shown on first launch")
    func shownOnFirstLaunch() {
        isolateSettings()
        let system = FakeSystem()
        #expect(OnboardingModel.shouldPresentAtLaunch(in: system.environment))
    }

    @Test("Not shown again once setup is complete and still valid")
    func hiddenOnceComplete() {
        isolateSettings()
        let system = FakeSystem()
        system.mic = true
        system.accessibility = true
        system.transcription = true
        Settings.onboardingCompletedVersion = OnboardingModel.currentVersion

        #expect(!OnboardingModel.shouldPresentAtLaunch(in: system.environment))
    }

    @Test("Comes back if a permission is revoked later")
    func returnsWhenPermissionRevoked() {
        isolateSettings()
        let system = FakeSystem()
        system.mic = true
        system.accessibility = true
        system.transcription = true
        Settings.onboardingCompletedVersion = OnboardingModel.currentVersion

        // The user turns Accessibility off in System Settings. Without this the
        // app silently stops working and says nothing about why.
        system.accessibility = false
        #expect(OnboardingModel.shouldPresentAtLaunch(in: system.environment))
    }

    @Test("A returning user lands on what is actually missing")
    func resumesAtTheMissingStep() {
        isolateSettings()
        let system = FakeSystem()
        system.transcription = true
        system.mic = true
        Settings.onboardingCompletedVersion = OnboardingModel.currentVersion

        let model = OnboardingModel(environment: system.environment)
        #expect(model.step == .accessibility)
    }
}

/// The live wiring, as far as it can be exercised off a real machine.
///
/// Nothing here touches `KeychainStore`: it reads and writes the real login
/// keychain under a fixed service name, so a test that stored a key would
/// overwrite the key of whoever ran it. The cases below use a provider id that
/// has no keychain entry, which exercises the base-URL branch deterministically
/// instead of depending on what happens to be stored on the machine.
@Suite("Onboarding environment")
@MainActor
struct OnboardingEnvironmentTests {

    @Test("On-device is not configured until the model has finished downloading")
    func onDeviceNeedsAReadyModel() {
        let model = makeModel()
        model.transcriptionSource = .onDevice

        // A variant has been chosen but `localState` is still idle. Treating
        // this as configured is what would let setup finish on an app that
        // cannot yet transcribe a word.
        #expect(!model.isTranscriptionConfigured)
    }

    @Test("A custom endpoint counts as configured without any key")
    func customEndpointNeedsNoKey() {
        let model = makeModel()
        // Via on-device first: `useHostedForAllModes` only rewrites modes that
        // are currently local, so this is what actually moves them all.
        model.transcriptionSource = .onDevice
        model.transcriptionSource = .cloud(providerId: "local-llm")
        #expect(!model.isTranscriptionConfigured)

        Settings.setBaseUrl("http://localhost:11434/v1", for: "local-llm")
        #expect(model.isTranscriptionConfigured)
    }

    @Test("The live environment reports the app model's transcription state")
    func liveEnvironmentReflectsTheModel() {
        let model = makeModel()
        let environment = OnboardingModel.Environment.live(model: model)

        model.transcriptionSource = .onDevice
        #expect(!environment.transcriptionConfigured())

        model.transcriptionSource = .cloud(providerId: "local-llm")
        Settings.setBaseUrl("http://localhost:11434/v1", for: "local-llm")
        // A constant `false` here — which is what this closure used to be —
        // means setup can never be satisfied and the flow returns on every
        // single launch.
        #expect(environment.transcriptionConfigured())
    }
}
