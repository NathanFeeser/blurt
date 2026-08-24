import AppKit
import Combine
import OpenDictCore

/// Everything the settings UI reads and writes, and the single place that
/// pushes configuration into the engine.
///
/// The engine is not observable and does not persist anything by design — it is
/// shared with iOS and Windows. Keeping storage and UI state on this side of
/// the boundary is what lets the core stay platform-free.
@MainActor
final class AppModel: ObservableObject {
    let engine: DictationEngine

    @Published var modes: [Mode] {
        didSet { ModeStore.save(modes); apply() }
    }
    @Published var vocabulary: [String] {
        didSet {
            Settings.vocabularyTerms = vocabulary
            apply()
        }
    }
    @Published var activeModeId: String {
        didSet {
            Settings.activeModeId = activeModeId
            apply()
        }
    }
    /// Bumped whenever a key changes, so views showing key state refresh.
    @Published private(set) var credentialsRevision = 0

    @Published private(set) var localState: WhisperKitTranscriber.State = .idle
    private var localTranscriber: WhisperKitTranscriber?

    init(engine: DictationEngine) {
        self.engine = engine
        self.modes = ModeStore.load()
        self.vocabulary = Settings.vocabularyTerms
        self.activeModeId = Settings.activeModeId
        apply()

        // Restore the on-device model if one was chosen. Loading is async and
        // non-blocking; until it finishes, on-device modes report that the model
        // is still loading rather than hanging.
        if let variant = Settings.localModelVariant {
            enableLocalModel(variant: variant)
        }
    }

    // MARK: - On-device transcription

    func enableLocalModel(variant: String) {
        Settings.localModelVariant = variant

        let transcriber = localTranscriber ?? WhisperKitTranscriber(variant: variant)
        transcriber.onStateChange = { [weak self] state in
            self?.localState = state
        }
        localTranscriber = transcriber
        localState = transcriber.state

        engine.setLocalTranscriber(transcriber: transcriber)
        transcriber.prepare(variant: variant)
    }

    func disableLocalModel() {
        Settings.localModelVariant = nil
        localTranscriber?.unload()
        localTranscriber = nil
        localState = .idle
        engine.setLocalTranscriber(transcriber: nil)
    }

    var localModelVariant: String? { Settings.localModelVariant }

    /// Point every mode's transcription at the on-device model.
    ///
    /// Enabling on-device otherwise changes nothing for the apps a user actually
    /// works in: their per-app modes keep their hosted provider and quietly win
    /// over the Private preset, which matches no apps at all.
    func useLocalForAllModes() {
        modes = modes.map { mode in
            var m = mode
            m.stt.providerId = "local"
            m.stt.model = Settings.localModelVariant ?? m.stt.model
            return m
        }
    }

    /// Point every mode's transcription back at a hosted provider.
    func useHostedForAllModes(providerId: String = "groq") {
        modes = modes.map { mode in
            var m = mode
            guard ["local", "whisperkit", "on-device"].contains(m.stt.providerId) else {
                return m
            }
            m.stt.providerId = providerId
            m.stt.model = "whisper-large-v3-turbo"
            return m
        }
    }

    /// The single question most users are actually answering: where does
    /// transcription happen? Modes exist to vary this per app, but that is an
    /// advanced case, and making it the primary interface made basic setup a
    /// scavenger hunt across four tabs.
    enum TranscriptionSource: Equatable {
        case onDevice
        case cloud(providerId: String)
    }

    var transcriptionSource: TranscriptionSource {
        get {
            if allModesAreLocal { return .onDevice }
            return .cloud(providerId: modes.first?.stt.providerId ?? "groq")
        }
        set {
            switch newValue {
            case .onDevice:
                useLocalForAllModes()
            case .cloud(let providerId):
                useHostedForAllModes(providerId: providerId)
            }
        }
    }

    /// Whether every mode agrees on where transcription happens. When they do
    /// not, the General tab says so rather than silently showing one of them.
    var transcriptionIsUniform: Bool {
        guard let first = modes.first?.stt.providerId else { return true }
        return modes.allSatisfy { $0.stt.providerId == first }
    }

    /// Cleanup, applied across every mode. Per-mode overrides live in Modes.
    var cleanupEnabledEverywhere: Bool {
        !modes.isEmpty && modes.allSatisfy { $0.cleanup != nil }
    }

    func setCleanupEverywhere(_ enabled: Bool) {
        modes = modes.map { mode in
            var m = mode
            if enabled {
                m.cleanup =
                    m.cleanup
                    ?? LlmConfig(
                        providerId: "groq", model: "openai/gpt-oss-120b",
                        reasoningEffort: "low")
            } else {
                m.cleanup = nil
            }
            return m
        }
    }

    func setCleanupModelEverywhere(providerId: String, model: String) {
        modes = modes.map { mode in
            var m = mode
            guard m.cleanup != nil else { return m }
            m.cleanup?.providerId = providerId
            m.cleanup?.model = model
            return m
        }
    }

    var cleanupProviderId: String { modes.compactMap { $0.cleanup?.providerId }.first ?? "groq" }
    var cleanupModel: String {
        modes.compactMap { $0.cleanup?.model }.first ?? "openai/gpt-oss-120b"
    }

    var allModesAreLocal: Bool {
        !modes.isEmpty
            && modes.allSatisfy { ["local", "whisperkit", "on-device"].contains($0.stt.providerId) }
    }

    /// Add the fully offline preset, unless it is already there.
    func addPrivateMode() {
        let preset = privateMode()
        guard !modes.contains(where: { $0.id == preset.id }) else { return }
        modes.append(preset)
    }

    /// Push the whole configuration into the engine. Cheap, and doing it
    /// wholesale avoids a class of bugs where one field is updated and another
    /// silently is not.
    func apply() {
        for provider in KeychainStore.knownProviders {
            let key = KeychainStore.get(for: provider)
            let base = Settings.baseUrl(for: provider)
            guard key != nil || !base.isEmpty else { continue }
            engine.setCredentials(
                providerId: provider,
                creds: ProviderCredentials(baseUrl: base, apiKey: key)
            )
        }

        let list = modes.isEmpty ? starterModes() : modes
        engine.setModes(modes: list)
        // The stored id can point at a mode the user deleted.
        let target = list.contains { $0.id == activeModeId } ? activeModeId : list[0].id
        try? engine.setActiveMode(modeId: target)
        engine.setVocabulary(vocabulary: Vocabulary(terms: vocabulary))
    }

    func setKey(_ value: String?, for provider: String) {
        KeychainStore.set(value, for: provider)
        credentialsRevision += 1
        apply()
    }

    func setBaseUrl(_ value: String, for provider: String) {
        Settings.setBaseUrl(value, for: provider)
        credentialsRevision += 1
        apply()
    }

    func hasKey(for provider: String) -> Bool {
        KeychainStore.get(for: provider)?.isEmpty == false
    }

    // MARK: - Mode editing

    func addMode() {
        modes.append(newMode(id: "mode-\(UUID().uuidString.prefix(8))", name: "New Mode"))
    }

    func duplicate(_ mode: Mode) {
        var copy = mode
        copy.id = "mode-\(UUID().uuidString.prefix(8))"
        copy.name = "\(mode.name) copy"
        modes.append(copy)
    }

    func delete(_ mode: Mode) {
        // Never leave the user with nothing: the engine falls back to its own
        // defaults, but a UI showing an empty list is just confusing.
        guard modes.count > 1 else { return }
        modes.removeAll { $0.id == mode.id }
        if activeModeId == mode.id, let first = modes.first {
            activeModeId = first.id
        }
    }

    func resetModes() {
        modes = starterModes()
    }

    /// Which mode would run for the given app, answered by the core so the UI
    /// cannot disagree with what actually runs.
    func resolvedMode(bundleId: String?) -> Mode {
        engine.resolveModeFor(
            ctx: AppContext(
                bundleId: bundleId, appName: nil, windowTitle: nil,
                surroundingText: nil, selectedText: nil))
    }

    /// True when a mode claimed this app rather than the fallback being used.
    func modeMatchedApp(_ bundleId: String?) -> Bool {
        guard let bundleId = bundleId?.lowercased() else { return false }
        return modes.contains { mode in
            mode.appMatches.contains { !$0.isEmpty && bundleId.contains($0.lowercased()) }
        }
    }
}

/// Mode persistence, using the core's JSON so a mode file written on a Mac
/// loads unchanged on Windows and there is one schema to version.
enum ModeStore {
    private static let key = "modesJSON"

    static func load() -> [Mode] {
        guard let json = UserDefaults.standard.string(forKey: key), !json.isEmpty else {
            return starterModes()
        }
        do {
            let modes = try modesFromJson(json: json)
            return modes.isEmpty ? starterModes() : modes
        } catch {
            // Corrupt storage should not brick the app into an unusable state.
            Diag.log("stored modes were unreadable, falling back to the starter set: \(error)")
            return starterModes()
        }
    }

    static func save(_ modes: [Mode]) {
        UserDefaults.standard.set(modesToJson(modes: modes), forKey: key)
    }

    static func exportJSON(_ modes: [Mode]) -> String {
        modesToJson(modes: modes)
    }

    static func importJSON(_ json: String) throws -> [Mode] {
        try modesFromJson(json: json)
    }
}

// Mode comes from the core as a plain record; List needs an identity for it.
extension Mode: Identifiable {}
