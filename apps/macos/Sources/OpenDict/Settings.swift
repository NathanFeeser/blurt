import Foundation
import OpenDictCore

/// Non-secret preferences. Keys never appear here — those live in the Keychain.
enum Settings {
    // Computed, not stored: a stored global of a non-Sendable type is a Swift 6
    // concurrency error, and `.standard` is already a cheap cached lookup.
    private static var d: UserDefaults { .standard }

    enum Key {
        static let hotkey = "hotkey"
        static let commandHotkey = "commandHotkey"
        static let sttProvider = "sttProvider"
        static let sttModel = "sttModel"
        static let llmProvider = "llmProvider"
        static let llmModel = "llmModel"
        static let cleanupEnabled = "cleanupEnabled"
        static let reasoningEffort = "reasoningEffort"
        static let preferAccessibilityInsert = "preferAccessibilityInsert"
        static let readScreenContext = "readScreenContext"
        static let vocabulary = "vocabulary"
        static let activeModeId = "activeModeId"
        static let baseUrlPrefix = "baseUrl."
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.hotkey: HotkeyMonitor.Key.rightOption.rawValue,
            // Right Command: present on every Mac keyboard and, held alone,
            // bound to nothing.
            Key.commandHotkey: HotkeyMonitor.Key.rightCommand.rawValue,
            Key.sttProvider: "groq",
            Key.sttModel: "whisper-large-v3-turbo",
            Key.llmProvider: "groq",
            // Chosen by live measurement, not vibes — see the decision log in
            // docs/PLAN.md.
            Key.llmModel: "openai/gpt-oss-120b",
            Key.cleanupEnabled: true,
            // Cleanup is a formatting task, not a reasoning one. Measured on
            // gpt-oss-120b: "low" spends 8 reasoning tokens against ~240 for
            // the default, cutting cleanup latency by about a third with no
            // regression on self-corrections or spoken formatting commands.
            Key.reasoningEffort: "low",
            Key.preferAccessibilityInsert: true,
            Key.readScreenContext: true,
            Key.vocabulary: "",
            Key.activeModeId: "default",
        ])
    }

    static var hotkey: HotkeyMonitor.Key {
        get { HotkeyMonitor.Key(rawValue: d.string(forKey: Key.hotkey) ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    /// The command-mode key. Never the same as the dictation key: one physical
    /// key cannot drive two gestures, and silently sharing it would make one of
    /// them look broken.
    static var commandHotkey: HotkeyMonitor.Key {
        get {
            let stored =
                HotkeyMonitor.Key(rawValue: d.string(forKey: Key.commandHotkey) ?? "")
                ?? .rightCommand
            return stored == hotkey ? fallbackCommandKey(avoiding: hotkey) : stored
        }
        set { d.set(newValue.rawValue, forKey: Key.commandHotkey) }
    }

    private static func fallbackCommandKey(avoiding taken: HotkeyMonitor.Key) -> HotkeyMonitor.Key {
        HotkeyMonitor.Key.allCases.first { $0 != taken } ?? .rightCommand
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
    /// Empty string means "omit the parameter", which local servers that reject
    /// unknown fields require.
    static var reasoningEffort: String? {
        get {
            let v = d.string(forKey: Key.reasoningEffort) ?? "low"
            return v.isEmpty ? nil : v
        }
        set { d.set(newValue ?? "", forKey: Key.reasoningEffort) }
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

    /// Which mode is used when no mode claims the frontmost app.
    static var activeModeId: String {
        get { d.string(forKey: Key.activeModeId) ?? "default" }
        set { d.set(newValue, forKey: Key.activeModeId) }
    }

    /// Optional custom endpoint per provider. Empty means "use the built-in
    /// default", which the core fills in.
    static func baseUrl(for providerId: String) -> String {
        d.string(forKey: Key.baseUrlPrefix + providerId) ?? ""
    }

    static func setBaseUrl(_ value: String, for providerId: String) {
        d.set(value.trimmingCharacters(in: .whitespaces), forKey: Key.baseUrlPrefix + providerId)
    }
}
