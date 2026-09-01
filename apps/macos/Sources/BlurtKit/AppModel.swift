import AppKit
import Combine
import BlurtCore

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
    /// Bumped whenever history changes, so open views reload. History lives in
    /// SQLite rather than in a `@Published` array — it outlives the process and
    /// can be thousands of rows, neither of which suits keeping it in memory.
    @Published private(set) var historyRevision = 0

    @Published private(set) var localState: WhisperKitTranscriber.State = .idle
    private var localTranscriber: WhisperKitTranscriber?

    init(engine: DictationEngine) {
        self.engine = engine
        self.modes = ModeStore.load()
        self.vocabulary = Settings.vocabularyTerms
        self.activeModeId = Settings.activeModeId
        apply()
        openHistoryIfEnabled()

        // Restore the on-device model if one was chosen. Loading is async and
        // non-blocking; until it finishes, on-device modes report that the model
        // is still loading rather than hanging.
        if let variant = Settings.localModelVariant {
            enableLocalModel(variant: variant)
        }
    }

    // MARK: - History

    /// Where the history database lives. Application Support, not Documents:
    /// this is app state the user did not create as a file, and it should not
    /// show up in their documents folder.
    ///
    /// Swappable for the same reason `Settings.defaults` is — a test that builds
    /// an `AppModel` must not write into the real history the user is keeping.
    nonisolated(unsafe) static var historyURL: URL = defaultHistoryURL()

    nonisolated static func defaultHistoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Blurt/history.sqlite3")
    }

    var historyEnabled: Bool {
        get { Settings.historyEnabled }
        set {
            Settings.historyEnabled = newValue
            openHistoryIfEnabled()
            historyRevision += 1
        }
    }

    var historyLimit: Int {
        get { Settings.historyLimit }
        set {
            Settings.historyLimit = newValue
            // The cap is applied by the core on write, so it has to be reopened
            // for a new value to take effect.
            openHistoryIfEnabled()
        }
    }

    /// Open the store, or close it if history is switched off.
    ///
    /// Switching off does not delete anything — that is `clearHistory()`, which
    /// is a different question and deserves its own deliberate answer.
    private func openHistoryIfEnabled() {
        guard Settings.historyEnabled else {
            engine.closeHistory()
            return
        }
        do {
            try engine.openHistory(
                path: Self.historyURL.path, limit: UInt32(Settings.historyLimit))
        } catch {
            // Dictation still works without history; a broken database is not a
            // reason to refuse to transcribe.
            Diag.log("could not open history, continuing without it: \(error)")
        }
    }

    func historyRecent(limit: Int = 200) -> [HistoryEntry] {
        (try? engine.historyRecent(limit: UInt32(limit))) ?? []
    }

    func historySearch(_ query: String, limit: Int = 200) -> [HistoryEntry] {
        (try? engine.historySearch(query: query, limit: UInt32(limit))) ?? []
    }

    func deleteHistoryEntry(_ id: Int64) {
        try? engine.historyDelete(id: id)
        historyRevision += 1
    }

    /// Delete every entry, whether or not recording is currently on.
    ///
    /// Switching history off closes the store, so this has to reopen it to have
    /// anything to delete — otherwise "clear my history" would appear to work
    /// while leaving every past dictation on disk, which is the worst possible
    /// outcome for a privacy control.
    func clearHistory() {
        let wasOpen = engine.historyIsOpen()
        if !wasOpen {
            try? engine.openHistory(
                path: Self.historyURL.path, limit: UInt32(Settings.historyLimit))
        }
        try? engine.historyClear()
        if !wasOpen {
            engine.closeHistory()
        }
        historyRevision += 1
    }

    func noteHistoryChanged() {
        historyRevision += 1
    }

    /// Re-run cleanup over a stored transcript with a different mode. The stored
    /// entry is not modified — this answers "what would this mode have done?"
    func rerun(entryId: Int64, modeId: String) async throws -> DictationResult {
        try await engine.rerunCleanup(entryId: entryId, modeId: modeId)
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
        // `KeychainStore.set` deletes the item for a nil or empty value, so
        // this mirrors what is now actually stored.
        keyPresence[provider] = value?.isEmpty == false
        credentialsRevision += 1
        apply()
    }

    func setBaseUrl(_ value: String, for provider: String) {
        Settings.setBaseUrl(value, for: provider)
        credentialsRevision += 1
        apply()
    }

    /// Whether a provider has a key, remembered rather than re-read.
    ///
    /// This is asked from places that run constantly: the status menu rebuilds
    /// on every application switch and asks twice, the setup flow's timer asks
    /// once a second, and a settings view asks on every render. Each call used
    /// to be a keychain read.
    ///
    /// A keychain read is not free and is not always silent. When the running
    /// binary is not the one that created the item — a different signing
    /// identity, which is every developer moving between a local build and a
    /// released one — macOS puts up a modal password prompt per read. That
    /// turned switching applications into a login password prompt, several
    /// times over. Whether the prompt is warranted is between the user and the
    /// keychain; asking hundreds of times is ours.
    ///
    /// `setKey` is the only thing in this app that changes a key, so it updates
    /// the cache directly and nothing else can make it stale.
    private var keyPresence: [String: Bool] = [:]

    func hasKey(for provider: String) -> Bool {
        if let known = keyPresence[provider] { return known }
        let present = KeychainStore.get(for: provider)?.isEmpty == false
        keyPresence[provider] = present
        return present
    }

    /// Whether transcription could actually run right now.
    ///
    /// "Configured" has to mean usable rather than merely chosen: an on-device
    /// model that is still downloading has been picked but cannot transcribe a
    /// word, and letting setup finish on one would hand the user a working
    /// hotkey attached to nothing. A custom base URL counts on its own — local
    /// endpoints like Ollama and LM Studio take no key.
    var isTranscriptionConfigured: Bool {
        switch transcriptionSource {
        case .onDevice:
            if case .ready = localState { return true }
            return false
        case .cloud(let providerId):
            return hasKey(for: providerId) || !Settings.baseUrl(for: providerId).isEmpty
        }
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
        guard let json = Settings.defaults.string(forKey: key), !json.isEmpty else {
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
        Settings.defaults.set(modesToJson(modes: modes), forKey: key)
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
