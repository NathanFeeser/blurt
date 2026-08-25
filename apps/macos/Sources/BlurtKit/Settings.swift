import Foundation
import BlurtCore

/// Non-secret preferences. Keys never appear here — those live in the Keychain.
enum Settings {
    /// Swappable so tests run against an isolated suite instead of writing to
    /// the user's real preferences.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    private static var d: UserDefaults { defaults }

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
        static let localModelVariant = "localModelVariant"
        static let activeModeId = "activeModeId"
        static let inputDeviceUID = "inputDeviceUID"
        static let historyEnabled = "historyEnabled"
        static let historyLimit = "historyLimit"
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
            Key.historyEnabled: true,
            // A thousand dictations is months of heavy use and a few megabytes
            // of text. Large enough that history is worth searching, small
            // enough that nothing accumulates forever unnoticed.
            Key.historyLimit: 1000,
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

    /// The on-device model variant, or nil when on-device is switched off.
    /// Models are hundreds of megabytes, so nothing is downloaded until the user
    /// explicitly picks one.
    static var localModelVariant: String? {
        get {
            let v = d.string(forKey: Key.localModelVariant) ?? ""
            return v.isEmpty ? nil : v
        }
        set { d.set(newValue ?? "", forKey: Key.localModelVariant) }
    }

    /// Which mode is used when no mode claims the frontmost app.
    static var activeModeId: String {
        get { d.string(forKey: Key.activeModeId) ?? "default" }
        set { d.set(newValue, forKey: Key.activeModeId) }
    }

    /// The microphone to record from, by CoreAudio UID. Empty means "follow the
    /// system default", which is the old behaviour and stays the default.
    ///
    /// Pinning exists because the system default is a shared setting that other
    /// things change: connecting earbuds moves it, and dictation quality falls
    /// off a cliff without anything announcing it.
    static var inputDeviceUID: String? {
        get {
            let v = d.string(forKey: Key.inputDeviceUID) ?? ""
            return v.isEmpty ? nil : v
        }
        set { d.set(newValue ?? "", forKey: Key.inputDeviceUID) }
    }

    /// Whether finished dictations are written to the local history database.
    ///
    /// A master switch above the per-mode `recordHistory` flag: off here means
    /// the core is never given a store to write to at all.
    static var historyEnabled: Bool {
        get { d.bool(forKey: Key.historyEnabled) }
        set { d.set(newValue, forKey: Key.historyEnabled) }
    }

    /// How many entries to keep. Enforced by the core on every write.
    static var historyLimit: Int {
        get { max(1, d.integer(forKey: Key.historyLimit)) }
        set { d.set(max(1, newValue), forKey: Key.historyLimit) }
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
