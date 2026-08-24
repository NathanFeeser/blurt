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

    init(engine: DictationEngine) {
        self.engine = engine
        self.modes = ModeStore.load()
        self.vocabulary = Settings.vocabularyTerms
        self.activeModeId = Settings.activeModeId
        apply()
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
    }

    func resetModes() {
        modes = starterModes()
    }

    /// Which mode would run right now, given the frontmost app. Shown in the UI
    /// so per-app matching is visible rather than mysterious.
    func modeForFrontmostApp() -> Mode? {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        else { return nil }
        return modes.first { mode in
            mode.appMatches.contains { !$0.isEmpty && bundle.contains($0.lowercased()) }
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
