import Foundation
import OpenDictCore

/// Non-secret preferences. Keys never appear here — those live in the Keychain.
enum Settings {
    // Computed, not stored: a stored global of a non-Sendable type is a Swift 6
    // concurrency error, and `.standard` is already a cheap cached lookup.
    private static var d: UserDefaults { .standard }

    enum Key {
        static let hotkey = "hotkey"
        static let sttProvider = "sttProvider"
        static let sttModel = "sttModel"
        static let llmProvider = "llmProvider"
        static let llmModel = "llmModel"
        static let cleanupEnabled = "cleanupEnabled"
        static let preferAccessibilityInsert = "preferAccessibilityInsert"
        static let readScreenContext = "readScreenContext"
        static let vocabulary = "vocabulary"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.hotkey: HotkeyMonitor.Key.rightOption.rawValue,
            Key.sttProvider: "groq",
            Key.sttModel: "whisper-large-v3-turbo",
            Key.llmProvider: "groq",
            // Chosen by live measurement, not vibes — see the decision log in
            // docs/PLAN.md.
            Key.llmModel: "openai/gpt-oss-120b",
            Key.cleanupEnabled: true,
            Key.preferAccessibilityInsert: true,
            Key.readScreenContext: true,
            Key.vocabulary: "",
        ])
    }

    static var hotkey: HotkeyMonitor.Key {
        get { HotkeyMonitor.Key(rawValue: d.string(forKey: Key.hotkey) ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    static var sttProvider: String {
        get { d.string(forKey: Key.sttProvider) ?? "groq" }
        set { d.set(newValue, forKey: Key.sttProvider) }
    }
    static var sttModel: String {
        get { d.string(forKey: Key.sttModel) ?? "whisper-large-v3-turbo" }
        set { d.set(newValue, forKey: Key.sttModel) }
    }
    static var llmProvider: String {
        get { d.string(forKey: Key.llmProvider) ?? "groq" }
        set { d.set(newValue, forKey: Key.llmProvider) }
    }
    static var llmModel: String {
        get { d.string(forKey: Key.llmModel) ?? "openai/gpt-oss-120b" }
        set { d.set(newValue, forKey: Key.llmModel) }
    }
    static var cleanupEnabled: Bool {
        get { d.bool(forKey: Key.cleanupEnabled) }
        set { d.set(newValue, forKey: Key.cleanupEnabled) }
    }
    static var preferAccessibilityInsert: Bool {
        get { d.bool(forKey: Key.preferAccessibilityInsert) }
        set { d.set(newValue, forKey: Key.preferAccessibilityInsert) }
    }
    static var readScreenContext: Bool {
        get { d.bool(forKey: Key.readScreenContext) }
        set { d.set(newValue, forKey: Key.readScreenContext) }
    }
    static var vocabularyTerms: [String] {
        get {
            (d.string(forKey: Key.vocabulary) ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { d.set(newValue.joined(separator: ", "), forKey: Key.vocabulary) }
    }

    /// The single mode the Phase 0 app uses. Phase 1 replaces this with a real
    /// mode list and per-app matching.
    static func currentMode() -> Mode {
        Mode(
            id: "default",
            name: "Dictation",
            stt: SttConfig(providerId: sttProvider, model: sttModel, language: nil),
            cleanup: cleanupEnabled
                ? LlmConfig(providerId: llmProvider, model: llmModel) : nil,
            cleanupInstructions: nil,
            appMatches: [],
            allowCleanupSkip: true
        )
    }
}
