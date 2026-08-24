import AppKit
import OpenDictCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = DictationEngine()
    private let audio = AudioEngine()
    private let hotkey = HotkeyMonitor()
    private let overlay = RecordingOverlay()

    private var statusItem: NSStatusItem!
    private var lastResult: DictationResult?
    private var isBusy = false
    private var handsFreeCap: DispatchWorkItem?

    /// Ten minutes of 16 kHz mono is ~38 MB — generous for a long hands-free
    /// dictation, and a hard stop against one left running by accident.
    private static let maxRecordingSeconds: TimeInterval = 600

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("applicationDidFinishLaunching")
        Settings.registerDefaults()
        buildStatusItem()
        applySettingsToEngine()
        wireHotkey()

        Task { await startUp() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        audio.shutdown()
    }

    // MARK: - Start-up

    private func startUp() async {
        Diag.log("startUp begin; mic status=\(Permissions.statusDescription())")
        let mic = await Permissions.requestMicrophone()
        Diag.log("requestMicrophone -> \(mic); status now=\(Permissions.statusDescription())")
        if !mic {
            overlay.flashError("Microphone access denied")
            refreshMenu()
            return
        }

        // Prompting for Accessibility on first launch is deliberate: without it
        // the hotkey installs cleanly and then never fires, which is impossible
        // for a user to diagnose.
        Diag.log("accessibility granted=\(Permissions.accessibilityGranted())")
        if !Permissions.accessibilityGranted() {
            Permissions.requestAccessibility()
        }

        // Build the audio graph but do not open the microphone: the orange
        // indicator should light only while actually dictating.
        audio.prewarm()
        Diag.log("audio graph prewarmed")
        refreshMenu()
    }

    private func applySettingsToEngine() {
        for provider in KeychainStore.knownProviders {
            if let key = KeychainStore.get(for: provider) {
                engine.setCredentials(
                    providerId: provider,
                    creds: ProviderCredentials(baseUrl: "", apiKey: key)
                )
            }
        }
        engine.setModes(modes: [Settings.currentMode()])
        try? engine.setActiveMode(modeId: "default")
        engine.setVocabulary(vocabulary: Vocabulary(terms: Settings.vocabularyTerms))
        hotkey.key = Settings.hotkey
    }

    private func wireHotkey() {
        hotkey.onStart = { [weak self] in self?.beginDictation() }
        hotkey.onEnd = { [weak self] in self?.endDictation() }
        hotkey.onHandsFreeEngaged = { [weak self] in self?.engageHandsFree() }
        hotkey.onDiscard = { [weak self] in self?.discardDictation() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }
        audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.overlay.update(level: level) }
        }
        audio.onInterrupted = { [weak self] in
            Task { @MainActor in
                self?.hotkey.reset()
                self?.overlay.flashError("Audio device changed")
            }
        }
        hotkey.start()
    }

    // MARK: - Dictation flow

    private func beginDictation() {
        guard !isBusy else { return }
        do {
            try audio.beginRecording()
        } catch {
            Diag.log("could not start recording: \(error)")
            hotkey.reset()
            overlay.flashError(error.localizedDescription)
            return
        }
        overlay.show(.recording)
        armHandsFreeCap()
    }

    /// The key was double-tapped: keep recording with the key released.
    private func engageHandsFree() {
        overlay.show(.handsFree)
        Diag.log("hands-free engaged")
    }

    /// A tap too short to be dictation — usually the first half of a double-tap,
    /// or a stray brush of the key. Drop the audio without a round trip.
    private func discardDictation() {
        audio.cancelRecording()
        overlay.hide()
    }

    private func cancelDictation() {
        audio.cancelRecording()
        handsFreeCap?.cancel()
        overlay.hide()
    }

    /// Hands-free has no key held down to bound it, so a forgotten session would
    /// record until memory ran out. Cap it and finish cleanly.
    private func armHandsFreeCap() {
        handsFreeCap?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hotkey.isRecording else { return }
            Diag.log("hit the \(Int(Self.maxRecordingSeconds))s recording cap; finishing")
            self.hotkey.reset()
            self.endDictation()
        }
        handsFreeCap = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.maxRecordingSeconds, execute: work)
    }

    private func endDictation() {
        handsFreeCap?.cancel()
        let samples = audio.endRecording()
        // Guard against a stray tap of the modifier. 300 ms of audio is not a
        // sentence, and sending it wastes a request and risks a hallucination
        // on near-silence.
        guard samples.count > Int(sampleRate()) / 3 else {
            overlay.hide()
            return
        }

        overlay.show(.transcribing)
        isBusy = true

        Task { [engine, overlay] in
            // AX reads are synchronous IPC and can block; keep them off the
            // main thread even though everything else here is main-actor.
            let context: AppContext =
                Settings.readScreenContext
                ? await Task.detached { ContextReader.read(includeSelection: false) }.value
                : AppContext(
                    bundleId: nil, appName: nil, windowTitle: nil,
                    surroundingText: nil, selectedText: nil)

            do {
                let result = try await engine.transcribe(samples: samples, ctx: context)
                await MainActor.run {
                    self.finish(result)
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    Diag.log("transcription failed: \(error)")
                    overlay.flashError(Self.describe(error))
                }
            }
        }
    }

    private func finish(_ result: DictationResult) {
        isBusy = false
        lastResult = result
        overlay.hide()

        guard !result.finalText.isEmpty else {
            overlay.flashError("Nothing was said")
            return
        }

        let method = TextInserter.insert(
            result.finalText,
            preferAccessibility: Settings.preferAccessibilityInsert
        )
        Diag.log(
            "inserted via \(method.rawValue): "
                + "raw \(result.rawText.count) -> final \(result.finalText.count) chars, "
                + "audio \(result.audioDurationMs)ms, total \(result.timings.totalMs)ms "
                + "(stt \(result.timings.sttMs)ms, cleanup \(result.timings.cleanupMs)ms)")
        // Surfaced separately because it is the signature of the failure that is
        // hardest to notice: text that looks fine but is missing half of what
        // was said.
        if result.cleanupRan, result.finalText.count * 2 < result.rawText.count,
            result.rawText.count > 200
        {
            Diag.log("  WARNING cleanup shortened the text by more than half")
            Diag.log("  raw: \(result.rawText)")
            Diag.log("  final: \(result.finalText)")
        }

        // Cleanup failing is not fatal — the raw transcript was inserted — but
        // it must be visible, or a dead model looks exactly like a working one.
        if let cleanupError = result.cleanupError {
            Diag.log("cleanup FAILED, inserted raw transcript: \(cleanupError)")
        }
        refreshMenu()
    }

    private static func describe(_ error: Error) -> String {
        guard let dictError = error as? DictError else { return error.localizedDescription }
        switch dictError {
        case .Unauthorized: return "API key rejected"
        case .RateLimited: return "Rate limited"
        case .NotConfigured: return "No API key set"
        case .NoAudio: return "No audio captured"
        case .Network: return "Network error"
        default: return "Transcription failed"
        }
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "OpenDict")
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()

        let ready =
            Permissions.microphoneGranted() && Permissions.accessibilityGranted()
            && KeychainStore.get(for: Settings.sttProvider) != nil

        if ready {
            let key = Settings.hotkey.displayName
            for line in [
                "Hold \(key) to dictate",
                "Double-tap for hands-free, tap to finish",
                "Escape while recording cancels",
            ] {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else {
            menu.addItem(withTitle: "Setup incomplete", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        if !Permissions.accessibilityGranted() {
            add(menu, "Grant Accessibility access…", #selector(openAccessibility))
        }
        if !Permissions.microphoneGranted() {
            add(menu, "Grant Microphone access…", #selector(openMicrophone))
        }
        if KeychainStore.get(for: Settings.sttProvider) == nil {
            add(menu, "Set \(Settings.sttProvider) API key…", #selector(setApiKey))
        }

        if let last = lastResult, !last.finalText.isEmpty {
            menu.addItem(.separator())
            let preview = String(last.finalText.prefix(48))
            let item = NSMenuItem(
                title: "Copy last: \"\(preview)…\"", action: #selector(copyLast),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let timing = NSMenuItem(
                title: "  \(last.timings.totalMs) ms · \(last.sttModel)", action: nil,
                keyEquivalent: "")
            timing.isEnabled = false
            menu.addItem(timing)
        }

        menu.addItem(.separator())
        add(menu, "Set API Key…", #selector(setApiKey))
        add(menu, "Set Vocabulary…", #selector(setVocabulary))

        let cleanup = NSMenuItem(
            title: "Clean up with AI", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = Settings.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)


        let hotkeyMenu = NSMenu()
        for key in HotkeyMonitor.Key.allCases {
            let item = NSMenuItem(
                title: key.displayName, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = key == Settings.hotkey ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        menu.addItem(.separator())
        add(menu, "Quit OpenDict", #selector(NSApplication.terminate(_:)), target: NSApp)

        statusItem.menu = menu
    }

    private func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, target: AnyObject? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openMicrophone() { Permissions.openMicrophoneSettings() }

    @objc private func copyLast() {
        guard let text = lastResult?.finalText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleCleanup() {
        Settings.cleanupEnabled.toggle()
        applySettingsToEngine()
        refreshMenu()
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let key = HotkeyMonitor.Key(rawValue: raw)
        else { return }
        Settings.hotkey = key
        hotkey.key = key
        refreshMenu()
    }

    @objc private func setApiKey() {
        let provider = Settings.sttProvider
        guard
            let value = prompt(
                title: "\(provider) API key",
                message: "Stored in your login keychain. It is sent only to \(provider).",
                initial: KeychainStore.get(for: provider) ?? "",
                secure: true)
        else { return }
        KeychainStore.set(value, for: provider)
        applySettingsToEngine()
        refreshMenu()
    }

    @objc private func setVocabulary() {
        guard
            let value = prompt(
                title: "Custom vocabulary",
                message:
                    "Comma-separated names and jargon to bias transcription toward. Keep it short — providers cap this.",
                initial: Settings.vocabularyTerms.joined(separator: ", "),
                secure: false)
        else { return }
        Settings.vocabularyTerms =
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        applySettingsToEngine()
    }

    private func prompt(title: String, message: String, initial: String, secure: Bool) -> String? {
        // A menu-bar app has no key window, so the alert must be brought forward
        // explicitly or it opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field: NSTextField =
            secure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
