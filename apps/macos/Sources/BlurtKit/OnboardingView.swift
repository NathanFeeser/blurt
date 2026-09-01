import AppKit
import SwiftUI

/// The screens for `OnboardingModel`.
///
/// One window with one job. The settings window has five tabs and every option
/// this app has, which is the wrong thing to hand somebody who has not dictated
/// yet — this asks for exactly what it needs, in the order it needs it, and
/// explains each thing before asking for it.
struct OnboardingView: View {
    @ObservedObject var onboarding: OnboardingModel
    @ObservedObject var model: AppModel
    /// Called once the last step is done, so the window can close itself.
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 24)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 520)
        // System Settings does not announce a permission being granted, so the
        // flow polls for it. A second is slow enough to cost nothing and fast
        // enough that coming back from granting one lands on the next step
        // already, which is the difference between a flow that feels alive and
        // one that feels like a form.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            onboarding.refresh()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2).bold()
            Spacer()
            Text("Step \(onboarding.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            Button("Back") { onboarding.back() }
                .disabled(onboarding.step == .welcome)
            Spacer()
            Button(onboarding.step == .firstDictation ? "Finish" : "Continue") {
                onboarding.advance()
                // `advance` past the last step records completion rather than
                // moving anywhere, so this is how the window learns it is done.
                if onboarding.isFinished { onFinish() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!onboarding.canAdvance)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
    }

    private var title: String {
        switch onboarding.step {
        case .welcome: return "Welcome to Blurt"
        case .transcription: return "Where should transcription happen?"
        case .microphone: return "Microphone access"
        case .accessibility: return "Accessibility access"
        case .inputDevice: return "Which microphone?"
        case .firstDictation: return "Try it"
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch onboarding.step {
        case .welcome: WelcomeStep()
        case .transcription: TranscriptionStep(model: model)
        case .microphone: MicrophoneStep()
        case .accessibility: AccessibilityStep()
        case .inputDevice: InputDeviceStep()
        case .firstDictation: FirstDictationStep(onboarding: onboarding)
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hold a key, say what you mean, and the text lands wherever your cursor is.")
                .font(.title3)

            Text("Three things to set up first:")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                Requirement(
                    symbol: "key",
                    title: "Somewhere to transcribe",
                    detail: "An API key you bring, or a model that runs entirely on this Mac.")
                Requirement(
                    symbol: "mic",
                    title: "Your microphone",
                    detail: "Opened only while you hold the dictation key, never before.")
                Requirement(
                    symbol: "figure.stand",
                    title: "Accessibility access",
                    detail: "How the text gets typed into whatever app you are in. "
                        + "Blurt genuinely cannot work without it.")
            }

            Text("It ends with you dictating a sentence, so you leave knowing it works.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct Requirement: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Transcription

private struct TranscriptionStep: View {
    @ObservedObject var model: AppModel

    @State private var onDevice = false
    @State private var provider = "groq"
    @State private var key = ""
    @State private var variant =
        Settings.localModelVariant ?? WhisperKitTranscriber.suggestedVariants[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: sourceBinding) {
                Text("On this Mac — private, no API key, slower").tag(true)
                Text("A cloud provider — fastest, needs a key").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            if onDevice { onDeviceControls } else { cloudControls }
        }
        .onAppear {
            onDevice = model.transcriptionSource == .onDevice
            if case .cloud(let p) = model.transcriptionSource { provider = p }
        }
    }

    // Mirrors the General tab's binding: picking on-device has to both point the
    // modes at the local model and make sure one has been asked for, or the
    // choice silently selects a model that was never downloaded.
    private var sourceBinding: Binding<Bool> {
        Binding(
            get: { onDevice },
            set: { wantsLocal in
                onDevice = wantsLocal
                if wantsLocal {
                    if model.localModelVariant == nil { model.enableLocalModel(variant: variant) }
                    model.transcriptionSource = .onDevice
                } else {
                    model.transcriptionSource = .cloud(providerId: provider)
                }
            })
    }

    @ViewBuilder private var onDeviceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Model", selection: $variant) {
                    ForEach(WhisperKitTranscriber.suggestedVariants, id: \.self) { v in
                        Text(WhisperKitTranscriber.displayName(v)).tag(v)
                    }
                }
                .frame(maxWidth: 340)
                Button(model.localModelVariant == variant ? "Reload" : "Download") {
                    model.enableLocalModel(variant: variant)
                }
                .disabled(isDownloading)
            }
            localStatus
            Text(
                "The model is a few hundred megabytes and downloads once. Nothing you say "
                    + "ever leaves this Mac."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cloudControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $provider) {
                ForEach(KeychainStore.knownProviders, id: \.self) { p in
                    Text(p).tag(p)
                }
            }
            .frame(maxWidth: 240)
            .onChange(of: provider) { new in
                model.transcriptionSource = .cloud(providerId: new)
                key = ""
            }

            if model.hasKey(for: provider) {
                Label("Key saved to your keychain", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                HStack {
                    // Saved on submit rather than on every keystroke: this step
                    // advances the moment a key exists, and saving as you type
                    // would carry the screen away mid-paste.
                    SecureField("Paste your API key", text: $key)
                        .frame(maxWidth: 340)
                        .onSubmit(save)
                    Button("Save", action: save).disabled(key.isEmpty)
                }
                if provider == "groq" {
                    Link(
                        "Get a free Groq key",
                        destination: URL(string: "https://console.groq.com/keys")!
                    )
                    .font(.callout)
                }
            }

            Text("Keys are stored in the macOS keychain and are never written anywhere else.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.setKey(trimmed, for: provider)
        key = ""
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
            Text("No model downloaded yet.").font(.callout).foregroundStyle(.secondary)
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading \(Int(p * 100))%").font(.callout)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading and loading — slow the first time.").font(.callout)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red).lineLimit(3)
        }
    }
}

// MARK: - Microphone

private struct MicrophoneStep: View {
    /// Re-read on every tick so a denial that happens in another window shows up
    /// here. `Permissions` reads TCC directly, so there is nothing to observe.
    @State private var denied = Permissions.microphoneDenied()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                "Blurt opens the microphone while you hold the dictation key and closes it "
                    + "when you let go. The orange dot in your menu bar is on for exactly "
                    + "that long."
            )

            if denied {
                Label(
                    "macOS remembers a refusal and will not ask a second time.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Text("Switch Blurt on under Privacy & Security › Microphone.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Microphone Settings") { Permissions.openMicrophoneSettings() }
            } else {
                Button("Allow Microphone") {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        denied = Permissions.microphoneDenied()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            denied = Permissions.microphoneDenied()
        }
    }
}

// MARK: - Accessibility

private struct AccessibilityStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                "This one is worth reading, because you are about to let an app read and "
                    + "type into every other app."
            )
            .font(.title3)

            VStack(alignment: .leading, spacing: 14) {
                Requirement(
                    symbol: "keyboard",
                    title: "Typing your text where you want it",
                    detail: "Putting the transcript into the field you were in, without "
                        + "hijacking your clipboard.")
                Requirement(
                    symbol: "text.cursor",
                    title: "Reading the text you select",
                    detail: "Only when you hold the command key to edit a selection.")
            }

            Text(
                "Without it, the hotkey installs successfully and then never fires — no error, "
                    + "no dialog, nothing. That failure is the single most confusing thing this "
                    + "app can do, which is why setup stops here rather than letting you past it."
            )
            .font(.callout).foregroundStyle(.secondary)

            Button("Open Accessibility Settings") {
                // Prompt first: on a fresh install this is the dialog that
                // deep-links into the right pane with Blurt already listed.
                // macOS shows it only once per binary, so the button also opens
                // the pane directly for everyone it has stopped prompting.
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)

            Text("Find Blurt in the list and switch it on. This screen moves on by itself.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            // The escape hatch from the one dead end this flow can reach.
            // macOS works out accessibility trust when a process launches, so a
            // switch turned on underneath a running app may never reach it —
            // and then this screen refuses to continue while System Settings
            // insists the permission is granted.
            VStack(alignment: .leading, spacing: 8) {
                Text("Already switched it on and this screen has not noticed?")
                    .font(.callout)
                Text(
                    "macOS works this out when Blurt starts, so it sometimes takes a "
                        + "relaunch to see it. Nothing is lost — setup resumes here."
                )
                .font(.callout).foregroundStyle(.secondary)
                Button("Quit and Reopen Blurt") { Permissions.relaunch() }
            }
        }
    }
}

// MARK: - Input device

private struct InputDeviceStep: View {
    @State private var devices: [AudioInputDevice] = []
    @State private var uid = Settings.inputDeviceUID ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                "Worth ten seconds: the system default moves on its own when you connect "
                    + "earbuds, and a Bluetooth mic in hands-free mode drops words no model "
                    + "can recover."
            )

            Picker("", selection: $uid) {
                Text("System default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 380)
            .onChange(of: uid) { new in
                Settings.inputDeviceUID = new.isEmpty ? nil : new
                NotificationCenter.default.post(name: .blurtInputDeviceChanged, object: nil)
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            Text("You can change this later in Settings, under General.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear {
            devices = AudioDevices.inputDevices()
            uid = Settings.inputDeviceUID ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .blurtAudioDevicesChanged)) { _ in
            devices = AudioDevices.inputDevices()
        }
    }

    /// What is wrong with the microphone that would actually be used.
    private var warning: String? {
        let device =
            uid.isEmpty ? AudioDevices.defaultInputDevice() : devices.first { $0.uid == uid }
        guard let device else {
            return uid.isEmpty ? nil : "That microphone is not attached right now."
        }
        return AudioDevices.quality(of: device).warning
    }
}

// MARK: - First dictation

private struct FirstDictationStep: View {
    @ObservedObject var onboarding: OnboardingModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Click in the box, hold \(Settings.hotkey.displayName), say a sentence, let go.")
                .font(.title3)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 130)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.35))
                )
                .focused($focused)

            if onboarding.dictationSucceeded {
                Label(
                    "That is the whole app. Finish, and the key works everywhere.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Text(
                    "Escape while holding cancels. Double-tap the key to keep recording "
                        + "hands-free, then tap once to finish."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { focused = true }
        // Posted by the app delegate when a transcription actually lands
        // somewhere. Watching for text in the box instead would count typing.
        .onReceive(NotificationCenter.default.publisher(for: .blurtDictationCompleted)) { _ in
            onboarding.dictationSucceeded = true
        }
    }
}
