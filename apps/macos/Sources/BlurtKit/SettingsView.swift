import BlurtCore
import Combine
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case modes
    case history
    case providers
    case gestures
}

/// Which tab the settings window is showing, owned by the window so a menu item
/// can change it on a window that is already open.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        // General first, and it answers the whole setup question on one screen.
        // Modes are powerful but advanced; leading with them turned basic setup
        // into a hunt across several tabs.
        TabView(selection: $navigation.tab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ModesTab(model: model)
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.modes)
            HistoryTab(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            ProvidersTab(model: model)
                .tabItem { Label("Providers", systemImage: "key") }
                .tag(SettingsTab.providers)
            GesturesTab()
                .tabItem { Label("Gestures", systemImage: "hand.tap") }
                .tag(SettingsTab.gestures)
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var variant = Settings.localModelVariant
        ?? WhisperKitTranscriber.suggestedVariants[0]
    @State private var cloudProvider = "groq"
    @State private var cleanupModel = ""
    @State private var vocabularyText = ""
    @State private var inputDeviceUID = Settings.inputDeviceUID ?? ""
    @State private var inputDevices: [AudioInputDevice] = []

    private var usesOnDevice: Bool { model.transcriptionSource == .onDevice }

    /// What is wrong with the microphone that would actually be used — the
    /// pinned one, or the system default when nothing is pinned.
    private var microphoneWarning: String? {
        let device =
            inputDeviceUID.isEmpty
            ? AudioDevices.defaultInputDevice()
            : inputDevices.first { $0.uid == inputDeviceUID }
        guard let device else {
            return inputDeviceUID.isEmpty ? nil : "That microphone is not attached right now."
        }
        return AudioDevices.quality(of: device).warning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // --- Microphone ---------------------------------------------
                //
                // First, and above the model choice, because it decides more of
                // the output quality than the model does and is the only part
                // of the pipeline something else can change behind your back.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Microphone").font(.headline)
                    Picker("", selection: $inputDeviceUID) {
                        Text("System default").tag("")
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    .onChange(of: inputDeviceUID) { new in
                        Settings.inputDeviceUID = new.isEmpty ? nil : new
                        NotificationCenter.default.post(
                            name: .blurtInputDeviceChanged, object: nil)
                    }

                    if let warning = microphoneWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(
                        "Pinning a mic keeps dictation on it even when something else takes over "
                            + "the system default — connecting earbuds, for instance."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }

                // --- Transcription ------------------------------------------
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription").font(.headline)
                    if !model.transcriptionIsUniform {
                        Label(
                            "Your modes use different providers. Choosing here changes all of them.",
                            systemImage: "info.circle"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }

                    Picker("", selection: transcriptionBinding) {
                        Text("On this Mac — private, no API key").tag(true)
                        Text("Cloud provider").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if usesOnDevice {
                        HStack {
                            Picker("Model", selection: $variant) {
                                ForEach(WhisperKitTranscriber.suggestedVariants, id: \.self) { v in
                                    Text(WhisperKitTranscriber.displayName(v)).tag(v)
                                }
                            }
                            .frame(maxWidth: 330)
                            Button(model.localModelVariant == variant ? "Reload" : "Download") {
                                model.enableLocalModel(variant: variant)
                            }
                            .disabled(isDownloading)
                        }
                        localStatus.padding(.leading, 2)
                    } else {
                        HStack {
                            Picker("Provider", selection: $cloudProvider) {
                                ForEach(KeychainStore.knownProviders, id: \.self) { p in
                                    Text(p).tag(p)
                                }
                            }
                            .frame(maxWidth: 220)
                            .onChange(of: cloudProvider) { new in
                                model.transcriptionSource = .cloud(providerId: new)
                            }
                            if model.hasKey(for: cloudProvider) {
                                Label("key set", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            } else {
                                Label("needs a key — set it in Providers", systemImage: "key")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Divider()

                // --- Cleanup -------------------------------------------------
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Clean up with AI",
                        isOn: Binding(
                            get: { model.cleanupEnabledEverywhere },
                            set: { model.setCleanupEverywhere($0) })
                    )
                    .font(.headline)
                    Text(
                        "Removes filler words, applies spoken corrections, and formats the text. "
                            + "Adds roughly half a second and always sends the transcript to the "
                            + "model you pick."
                    )
                    .font(.caption).foregroundStyle(.secondary)

                    if model.cleanupEnabledEverywhere {
                        HStack {
                            TextField("openai/gpt-oss-120b", text: $cleanupModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                            Button("Apply") {
                                model.setCleanupModelEverywhere(
                                    providerId: model.cleanupProviderId, model: cleanupModel)
                            }
                            Text("via \(model.cleanupProviderId)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // --- Vocabulary ----------------------------------------------
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom vocabulary").font(.headline)
                    Text("Names and jargon that get misheard. One per line.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vocabularyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Text("\(vocabularyTerms.count) terms")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save") { model.vocabulary = vocabularyTerms }
                    }
                }

                Text(
                    "These apply to every mode. The Modes tab can override them per app."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear {
            vocabularyText = model.vocabulary.joined(separator: "\n")
            cleanupModel = model.cleanupModel
            if case .cloud(let p) = model.transcriptionSource { cloudProvider = p }
            inputDevices = AudioDevices.inputDevices()
            inputDeviceUID = Settings.inputDeviceUID ?? ""
        }
        // Re-enumerated on every hardware change rather than only on appear.
        // The settings window is built once and reused, so `onAppear` runs once
        // per launch: connect earbuds afterwards and they were missing from the
        // picker with no way to get them back short of quitting the app.
        .onReceive(NotificationCenter.default.publisher(for: .blurtAudioDevicesChanged)) { _ in
            inputDevices = AudioDevices.inputDevices()
        }
    }

    private var vocabularyTerms: [String] {
        vocabularyText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var transcriptionBinding: Binding<Bool> {
        Binding(
            get: { usesOnDevice },
            set: { onDevice in
                if onDevice {
                    if model.localModelVariant == nil { model.enableLocalModel(variant: variant) }
                    model.transcriptionSource = .onDevice
                } else {
                    model.transcriptionSource = .cloud(providerId: cloudProvider)
                }
            })
    }

    private var isDownloading: Bool {
        switch model.localState {
        case .loading, .downloading: return true
        default: return false
        }
    }

    @ViewBuilder private var localStatus: some View {
        switch model.localState {
        case .idle:
            Text("no model downloaded yet").font(.caption).foregroundStyle(.secondary)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("downloading \(Int(p * 100))%").font(.caption)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("downloading and loading — slow the first time").font(.caption)
            }
        case .ready:
            Label("ready — audio never leaves this Mac", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let m):
            Text(m).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

// MARK: - Modes

struct ModesTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?

    /// Bind by id, never by array index.
    ///
    /// The previous version captured an index. Deleting a mode shrank the array
    /// while SwiftUI still held the binding, and the next re-render subscripted
    /// past the end and trapped — so deleting the last mode in the list crashed
    /// the app every time. Looking up by id cannot go out of range, and the
    /// captured snapshot means even a getter racing a deletion returns
    /// something valid instead of crashing.
    private var selected: Binding<Mode>? {
        guard let id = selection ?? model.modes.first?.id,
            let snapshot = model.modes.first(where: { $0.id == id })
        else { return nil }
        return Binding(
            get: { model.modes.first(where: { $0.id == id }) ?? snapshot },
            set: { newValue in
                guard let index = model.modes.firstIndex(where: { $0.id == id }) else { return }
                model.modes[index] = newValue
            }
        )
    }

    /// Run an add action and select whatever it appended, so a new mode opens
    /// in the editor instead of leaving the user looking at the previous one.
    private func addAndSelect(_ add: () -> Void) -> String? {
        let before = Set(model.modes.map(\.id))
        add()
        return model.modes.first { !before.contains($0.id) }?.id ?? selection
    }

    /// Move the selection off a mode before removing it, so the editor unmounts
    /// rather than re-rendering against something that no longer exists.
    private func deleteMode(_ mode: Mode) {
        selection = model.modes.first { $0.id != mode.id }?.id
        model.delete(mode)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.modes) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(mode.name)
                                if mode.id == model.activeModeId {
                                    Text("fallback")
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                            }
                            HStack(spacing: 4) {
                                if ["local", "whisperkit", "on-device"]
                                    .contains(mode.stt.providerId)
                                {
                                    Image(systemName: "cpu")
                                        .font(.caption2).foregroundStyle(.green)
                                }
                                Text(
                                    mode.appMatches.isEmpty
                                        ? "no app match" : mode.appMatches.joined(separator: ", ")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                        .tag(mode.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        Button("New Mode") { selection = addAndSelect(model.addMode) }
                        Button("Private (on-device, no cleanup)") {
                            selection = addAndSelect(model.addPrivateMode)
                        }
                        .disabled(model.modes.contains { $0.id == "private" })
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        if let m = current { model.duplicate(m) }
                    } label: { Image(systemName: "doc.on.doc") }
                        .disabled(current == nil)
                    Button {
                        if let m = current { deleteMode(m) }
                    } label: { Image(systemName: "minus") }
                        .disabled(current == nil || model.modes.count <= 1)
                    Spacer()
                    Menu {
                        Button("Reset to Starter Modes") { model.resetModes() }
                        Button("Copy All Modes as JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                ModeStore.exportJSON(model.modes), forType: .string)
                        }
                        Button("Replace All from Clipboard JSON") { importFromClipboard() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            Group {
                if let binding = selected {
                    ModeEditor(mode: binding, model: model, onDelete: deleteMode)
                } else {
                    ContentUnavailableFallback()
                }
            }
            .frame(minWidth: 400)
        }
        .onAppear { if selection == nil { selection = model.modes.first?.id } }
    }

    private var current: Mode? {
        guard let id = selection else { return nil }
        return model.modes.first { $0.id == id }
    }

    private func importFromClipboard() {
        guard let json = NSPasteboard.general.string(forType: .string) else { return }
        do {
            let imported = try ModeStore.importJSON(json)
            guard !imported.isEmpty else { return }
            model.modes = imported
            selection = imported.first?.id
        } catch {
            NSSound.beep()
            Diag.log("mode import failed: \(error)")
        }
    }
}

private struct ContentUnavailableFallback: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Select a mode").foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct ModeEditor: View {
    @Binding var mode: Mode
    @ObservedObject var model: AppModel
    var onDelete: (Mode) -> Void

    private var appMatchText: Binding<String> {
        Binding(
            get: { mode.appMatches.joined(separator: ", ") },
            set: {
                mode.appMatches =
                    $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }

    private var cleanupEnabled: Binding<Bool> {
        Binding(
            get: { mode.cleanup != nil },
            set: { on in
                mode.cleanup =
                    on
                    ? LlmConfig(
                        providerId: "groq", model: "openai/gpt-oss-120b",
                        reasoningEffort: "low")
                    : nil
            })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Section {
                    LabeledContent("Name") {
                        TextField("", text: $mode.name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Applies to") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("slack, discord", text: appMatchText)
                                .textFieldStyle(.roundedBorder)
                            Text(
                                "Comma-separated fragments matched against the app's bundle id. "
                                    + "Leave empty for a mode you switch to manually."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(
                        "Use as the fallback when no mode matches",
                        isOn: Binding(
                            get: { model.activeModeId == mode.id },
                            set: { if $0 { model.activeModeId = mode.id } }
                        )
                    )
                    .disabled(model.activeModeId == mode.id)

                    Toggle("Keep dictations from this mode in History", isOn: $mode.recordHistory)
                    Text(
                        "Off means nothing spoken in this mode is written to disk. The Private "
                            + "preset ships with it off."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                Section {
                    Text("Transcription").font(.headline)
                    LabeledContent("Provider") {
                        TextField("groq", text: $mode.stt.providerId)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Model") {
                        TextField("whisper-large-v3-turbo", text: $mode.stt.model)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Language") {
                        TextField(
                            "auto-detect",
                            text: Binding(
                                get: { mode.stt.language ?? "" },
                                set: { mode.stt.language = $0.isEmpty ? nil : $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                Divider()

                Section {
                    Toggle("Clean up with AI", isOn: cleanupEnabled).font(.headline)
                    if mode.cleanup != nil {
                        LabeledContent("Provider") {
                            TextField(
                                "groq",
                                text: Binding(
                                    get: { mode.cleanup?.providerId ?? "" },
                                    set: { mode.cleanup?.providerId = $0 })
                            ).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Model") {
                            TextField(
                                "openai/gpt-oss-120b",
                                text: Binding(
                                    get: { mode.cleanup?.model ?? "" },
                                    set: { mode.cleanup?.model = $0 })
                            ).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Reasoning") {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { mode.cleanup?.reasoningEffort ?? "" },
                                    set: {
                                        mode.cleanup?.reasoningEffort = $0.isEmpty ? nil : $0
                                    })
                            ) {
                                Text("Low — fastest").tag("low")
                                Text("Medium").tag("medium")
                                Text("High").tag("high")
                                Text("Don't send").tag("")
                            }
                            .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extra instructions").font(.subheadline)
                            TextEditor(
                                text: Binding(
                                    get: { mode.cleanupInstructions ?? "" },
                                    set: { mode.cleanupInstructions = $0.isEmpty ? nil : $0 })
                            )
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3)))
                            Text(
                                "Added to the built-in rules, never replacing them. "
                                    + "The guarantees against summarising and acting on your "
                                    + "words always apply."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle(
                            "Skip cleanup when the transcript already looks clean",
                            isOn: $mode.allowCleanupSkip)
                        Text("Saves roughly 400–800 ms on short dictations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()
                HStack {
                    Button(role: .destructive) {
                        onDelete(mode)
                    } label: {
                        Label("Delete this mode", systemImage: "trash")
                    }
                    .disabled(model.modes.count <= 1)
                    Spacer()
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Providers

struct ProvidersTab: View {
    @ObservedObject var model: AppModel
    @State private var showAll = false

    /// Providers a mode actually references, plus any that already have a key.
    /// Showing all seven rows unconditionally made this tab mostly noise.
    private var inUse: [String] {
        var ids = Set(model.modes.map(\.stt.providerId))
        ids.formUnion(model.modes.compactMap { $0.cleanup?.providerId })
        ids.formUnion(KeychainStore.knownProviders.filter { model.hasKey(for: $0) })
        ids.subtract(["local", "whisperkit", "on-device"])
        return ids.sorted()
    }

    private var others: [String] {
        let shown = Set(inUse)
        return (KeychainStore.knownProviders + ["ollama", "lmstudio", "vllm"])
            .filter { !shown.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keys are stored in your login keychain and sent only to the provider they belong to.")
                    .font(.callout).foregroundStyle(.secondary)

                if inUse.isEmpty {
                    Text("Nothing to configure — you are running fully on-device.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(inUse, id: \.self) { provider in
                    ProviderRow(model: model, provider: provider)
                }

                DisclosureGroup("Other providers", isExpanded: $showAll) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Any OpenAI-compatible endpoint works. Local servers such as Ollama, "
                                + "LM Studio, and vLLM need no key — set a base URL if yours is "
                                + "not on the default port."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(others, id: \.self) { provider in
                            ProviderRow(model: model, provider: provider, keyOptional: true)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
            .padding(20)
        }
    }
}

struct ProviderRow: View {
    @ObservedObject var model: AppModel
    let provider: String
    var keyOptional = false

    @State private var key = ""
    @State private var baseUrl = ""
    @State private var status: String?
    @State private var showEndpoint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider).font(.headline)
                if model.hasKey(for: provider) {
                    Text("key set").font(.caption).foregroundStyle(.green)
                } else if !keyOptional {
                    Text("no key").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button("Test") { test() }
            }
            HStack {
                SecureField(keyOptional ? "API key (optional)" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.setKey(key, for: provider)
                    key = ""
                    status = "saved"
                }
                .disabled(key.isEmpty)
            }
            DisclosureGroup("Custom endpoint", isExpanded: $showEndpoint) {
                HStack {
                    TextField("Base URL (empty uses the default)", text: $baseUrl)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.setBaseUrl(baseUrl, for: provider) }
                    Button("Save") { model.setBaseUrl(baseUrl, for: provider) }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            baseUrl = Settings.baseUrl(for: provider)
            showEndpoint = !baseUrl.isEmpty
        }
    }

    private func test() {
        status = "checking…"
        Task {
            do {
                let ok = try await model.engine.checkCredentials(providerId: provider)
                status = ok ? "reachable" : "reachable, unexpected response"
            } catch {
                status = AppDelegate.describe(error)
            }
        }
    }
}

// MARK: - Gestures

struct GesturesTab: View {
    @State private var dictation = Settings.hotkey
    @State private var command = Settings.commandHotkey

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Dictation key", selection: $dictation) {
                ForEach(HotkeyMonitor.Key.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .onChange(of: dictation) { new in
                Settings.hotkey = new
                command = Settings.commandHotkey
                NotificationCenter.default.post(name: .blurtHotkeysChanged, object: nil)
            }

            Picker("Command key", selection: $command) {
                ForEach(HotkeyMonitor.Key.allCases.filter { $0 != dictation }, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .onChange(of: command) { new in
                Settings.commandHotkey = new
                NotificationCenter.default.post(name: .blurtHotkeysChanged, object: nil)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Hold the dictation key and speak", systemImage: "mic")
                Label("Double-tap it for hands-free, tap once to finish", systemImage: "hand.tap")
                Label(
                    "Select text and hold the command key to edit it",
                    systemImage: "text.cursor")
                Label("Escape while recording cancels", systemImage: "escape")
            }
            .font(.callout)
            Spacer()
        }
        .padding(20)
    }
}

extension Notification.Name {
    static let blurtHotkeysChanged = Notification.Name("blurtHotkeysChanged")
    static let blurtInputDeviceChanged = Notification.Name("blurtInputDeviceChanged")
    /// A transcription actually landed somewhere. The setup flow's last step
    /// waits on this: it is the only proof the whole chain works.
    static let blurtDictationCompleted = Notification.Name("blurtDictationCompleted")
}
