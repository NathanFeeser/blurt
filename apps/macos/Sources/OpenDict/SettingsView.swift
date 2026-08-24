import OpenDictCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            ModesTab(model: model)
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            ProvidersTab(model: model)
                .tabItem { Label("Providers", systemImage: "key") }
            VocabularyTab(model: model)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            GesturesTab()
                .tabItem { Label("Gestures", systemImage: "hand.tap") }
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: - Modes

struct ModesTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?

    private var selected: Binding<Mode>? {
        guard let id = selection ?? model.modes.first?.id,
            let index = model.modes.firstIndex(where: { $0.id == id })
        else { return nil }
        return Binding(
            get: { model.modes[index] },
            set: { model.modes[index] = $0 }
        )
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
                            Text(
                                mode.appMatches.isEmpty
                                    ? "no app match" : mode.appMatches.joined(separator: ", ")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .tag(mode.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { model.addMode() } label: { Image(systemName: "plus") }
                    Button {
                        if let m = current { model.duplicate(m) }
                    } label: { Image(systemName: "doc.on.doc") }
                        .disabled(current == nil)
                    Button {
                        if let m = current { model.delete(m) }
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
                    ModeEditor(mode: binding, model: model)
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
            }
            .padding(20)
        }
    }
}

// MARK: - Providers

struct ProvidersTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keys are stored in your login keychain and sent only to the provider they belong to.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(KeychainStore.knownProviders, id: \.self) { provider in
                    ProviderRow(model: model, provider: provider)
                }
                Divider()
                Text(
                    "Any OpenAI-compatible endpoint works: set a mode's provider to the id below "
                        + "and give it a base URL. Local servers such as Ollama, LM Studio, and "
                        + "vLLM need no key."
                )
                .font(.caption).foregroundStyle(.secondary)
                ForEach(["ollama", "lmstudio", "vllm"], id: \.self) { provider in
                    ProviderRow(model: model, provider: provider, keyOptional: true)
                }
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
            HStack {
                TextField("Base URL (leave empty for the default)", text: $baseUrl)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.setBaseUrl(baseUrl, for: provider) }
                Button("Save") { model.setBaseUrl(baseUrl, for: provider) }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { baseUrl = Settings.baseUrl(for: provider) }
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

// MARK: - Vocabulary

struct VocabularyTab: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names, jargon, and product names to bias transcription toward.")
                .font(.callout)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            Text(
                "One term per line. Providers cap how much of this they use — Whisper reads "
                    + "only the last ~224 tokens — so keep it to terms that actually get "
                    + "misheard rather than a glossary."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(terms.count) terms").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { model.vocabulary = terms }
            }
        }
        .padding(20)
        .onAppear { text = model.vocabulary.joined(separator: "\n") }
    }

    private var terms: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
                NotificationCenter.default.post(name: .openDictHotkeysChanged, object: nil)
            }

            Picker("Command key", selection: $command) {
                ForEach(HotkeyMonitor.Key.allCases.filter { $0 != dictation }, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .onChange(of: command) { new in
                Settings.commandHotkey = new
                NotificationCenter.default.post(name: .openDictHotkeysChanged, object: nil)
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
    static let openDictHotkeysChanged = Notification.Name("openDictHotkeysChanged")
}
