import Foundation
import BlurtCore
import Testing

@testable import BlurtKit

/// Isolated defaults and an isolated history file, so tests never touch the
/// user's real preferences or the dictations they are actually keeping.
@MainActor
func makeModel(_ name: String = UUID().uuidString) -> AppModel {
    let suite = UserDefaults(suiteName: "blurt.tests.\(name)")!
    suite.removePersistentDomain(forName: "blurt.tests.\(name)")
    Settings.defaults = suite
    Settings.registerDefaults()
    AppModel.historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("blurt-tests/\(name)/history.sqlite3")
    return AppModel(engine: DictationEngine())
}

@Suite("Mode management")
@MainActor
struct AppModelModeTests {

    @Test("Starts with the starter set")
    func startsWithStarterModes() {
        let model = makeModel()
        #expect(model.modes.count >= 4)
        #expect(model.modes.contains { $0.id == "default" })
        #expect(model.modes.contains { $0.id == "code" })
    }

    @Test("Deleting the fallback repoints it instead of leaving it dangling")
    func deletingFallbackRepoints() {
        let model = makeModel()
        let fallback = model.modes.first { $0.id == model.activeModeId }!
        model.delete(fallback)

        #expect(!model.modes.contains { $0.id == fallback.id })
        #expect(
            model.modes.contains { $0.id == model.activeModeId },
            "the fallback must point at a mode that still exists")
    }

    @Test("The last mode cannot be deleted")
    func cannotDeleteTheLastMode() {
        let model = makeModel()
        while model.modes.count > 1 {
            model.delete(model.modes.last!)
        }
        let survivor = model.modes[0]
        model.delete(survivor)
        #expect(model.modes.count == 1, "an empty mode list would leave the UI unusable")
    }

    @Test("Adding a mode gives it a unique id and no app matches")
    func addModeIsIsolated() {
        let model = makeModel()
        let before = Set(model.modes.map(\.id))
        model.addMode()
        let added = model.modes.first { !before.contains($0.id) }
        #expect(added != nil)
        #expect(added?.appMatches.isEmpty == true, "a new mode must not steal another's apps")
    }

    @Test("The Private preset is added once and is fully offline")
    func privatePresetIsIdempotentAndOffline() {
        let model = makeModel()
        model.addPrivateMode()
        model.addPrivateMode()
        let matches = model.modes.filter { $0.id == "private" }
        #expect(matches.count == 1, "adding twice must not duplicate it")
        #expect(matches.first?.cleanup == nil, "cleanup would send the transcript off-device")
        #expect(matches.first?.stt.providerId == "local")
    }

    @Test("Modes survive a save and reload")
    func modesPersist() {
        let name = UUID().uuidString
        let model = makeModel(name)
        model.addMode()
        let expected = model.modes.map(\.id)

        // A fresh model over the same defaults is what a relaunch looks like.
        let reloaded = AppModel(engine: DictationEngine())
        #expect(reloaded.modes.map(\.id) == expected)
    }

    @Test("Corrupt stored modes fall back to the starter set")
    func corruptStorageDoesNotBrickTheApp() {
        let name = UUID().uuidString
        _ = makeModel(name)
        Settings.defaults.set("{ not json", forKey: "modesJSON")
        let model = AppModel(engine: DictationEngine())
        #expect(model.modes.count >= 4)
    }
}

@Suite("Transcription source")
@MainActor
struct AppModelTranscriptionTests {

    @Test("Switching to on-device moves every mode, not just the fallback")
    func onDeviceAppliesEverywhere() {
        let model = makeModel()
        model.useLocalForAllModes()
        #expect(model.allModesAreLocal)
        #expect(model.transcriptionSource == .onDevice)
        #expect(
            model.modes.allSatisfy { $0.stt.providerId == "local" },
            "a per-app mode left on a hosted provider silently wins over the fallback")
    }

    @Test("Switching back only touches modes that were on-device")
    func switchingBackIsSelective() {
        let model = makeModel()
        model.useLocalForAllModes()
        model.useHostedForAllModes(providerId: "groq")
        #expect(!model.allModesAreLocal)
        #expect(model.modes.allSatisfy { $0.stt.providerId == "groq" })
    }

    @Test("Mixed providers are reported as not uniform")
    func mixedProvidersAreDetected() {
        let model = makeModel()
        var first = model.modes[0]
        first.stt.providerId = "local"
        model.modes[0] = first
        #expect(!model.transcriptionIsUniform, "General must not silently show one of several")
    }

    @Test("Cleanup can be switched off and back on across all modes")
    func cleanupTogglesEverywhere() {
        let model = makeModel()
        model.setCleanupEverywhere(false)
        #expect(model.modes.allSatisfy { $0.cleanup == nil })
        #expect(!model.cleanupEnabledEverywhere)

        model.setCleanupEverywhere(true)
        #expect(model.modes.allSatisfy { $0.cleanup != nil })
        #expect(model.cleanupEnabledEverywhere)
    }

    @Test("Changing the cleanup model leaves modes without cleanup alone")
    func cleanupModelChangeSkipsDisabledModes() {
        let model = makeModel()
        model.addPrivateMode()
        model.setCleanupModelEverywhere(providerId: "groq", model: "some-other-model")

        let priv = model.modes.first { $0.id == "private" }
        #expect(priv?.cleanup == nil, "the private mode must not gain a cleanup model")
        #expect(model.modes.contains { $0.cleanup?.model == "some-other-model" })
    }
}

@Suite("Per-app mode resolution")
@MainActor
struct AppModelResolutionTests {

    @Test("The core resolves the app's mode, and the UI agrees with it")
    func resolutionMatchesTheCore() {
        let model = makeModel()
        #expect(model.resolvedMode(bundleId: "com.microsoft.VSCode").id == "code")
        #expect(model.resolvedMode(bundleId: "com.tinyspeck.slackmacgap").id == "chat")
        #expect(model.resolvedMode(bundleId: "com.apple.Safari").id == model.activeModeId)
    }

    @Test("modeMatchedApp agrees with which mode was resolved")
    func matchFlagAgreesWithResolution() {
        let model = makeModel()
        #expect(model.modeMatchedApp("com.microsoft.VSCode"))
        #expect(!model.modeMatchedApp("com.apple.Safari"))
        #expect(!model.modeMatchedApp(nil))
    }

    @Test("A deleted mode stops claiming its apps")
    func deletedModeStopsMatching() {
        let model = makeModel()
        let code = model.modes.first { $0.id == "code" }!
        model.delete(code)
        #expect(!model.modeMatchedApp("com.microsoft.VSCode"))
        #expect(model.resolvedMode(bundleId: "com.microsoft.VSCode").id != "code")
    }
}
