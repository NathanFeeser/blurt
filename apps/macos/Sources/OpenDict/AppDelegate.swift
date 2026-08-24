import AppKit
import OpenDictCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = DictationEngine()
    private lazy var model = AppModel(engine: engine)
    private lazy var settingsWindow = SettingsWindow(model: model)
    private let audio = AudioEngine()
    private let hotkey = HotkeyMonitor()
    private let commandHotkey = HotkeyMonitor()
    private let overlay = RecordingOverlay()

    private var statusItem: NSStatusItem!
    private var lastResult: DictationResult?
    private var isBusy = false
    private var handsFreeCap: DispatchWorkItem?
    /// The selection captured when command mode started. Held because the user
    /// may click elsewhere while speaking, and the instruction applies to what
    /// was selected at the moment they pressed the key.
    private var pendingSelection: String?

    /// The last app that was frontmost other than OpenDict itself.
    ///
    /// `NSWorkspace.frontmostApplication` can report OpenDict once its own menu
    /// or settings window takes focus, which would make the menu claim the
    /// fallback mode was active no matter which app the user was really in.
    private var lastForegroundBundleId: String?
    private var lastForegroundAppName: String?

    /// Ten minutes of 16 kHz mono is ~38 MB — generous for a long hands-free
    /// dictation, and a hard stop against one left running by accident.
    private static let maxRecordingSeconds: TimeInterval = 600

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("applicationDidFinishLaunching")
        Settings.registerDefaults()
        NotificationCenter.default.addObserver(
            forName: .openDictHotkeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotkey.key = Settings.hotkey
                self.commandHotkey.key = Settings.commandHotkey
                self.refreshMenu()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Pull the strings out here: Notification is not Sendable, so it
            // cannot cross into the main-actor closure below, and these two
            // values are all we need anyway.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            let name = app?.localizedName
            MainActor.assumeIsolated {
                guard let self else { return }
                if let bundleId, bundleId != Bundle.main.bundleIdentifier {
                    self.lastForegroundBundleId = bundleId
                    self.lastForegroundAppName = name
                }
                self.refreshMenu()
            }
        }
        buildStatusItem()
        applySettingsToEngine()
        wireHotkey()

        Task { await startUp() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandHotkey.stop()
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
        model.apply()
        hotkey.key = Settings.hotkey
        commandHotkey.key = Settings.commandHotkey
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
        commandHotkey.onStart = { [weak self] in self?.beginCommand() }
        commandHotkey.onEnd = { [weak self] in self?.endCommand() }
        commandHotkey.onHandsFreeEngaged = { [weak self] in self?.engageHandsFree() }
        commandHotkey.onDiscard = { [weak self] in self?.discardDictation() }
        commandHotkey.onCancel = { [weak self] in self?.cancelDictation() }

        hotkey.start()
        commandHotkey.start()
    }

    // MARK: - Command mode

    /// Select text, hold the command key, say what to do with it.
    ///
    /// The selection is read at press time rather than on release: it takes up
    /// to 400 ms via the clipboard fallback, and doing it while the user is
    /// still speaking hides that latency completely.
    private func beginCommand() {
        guard !isBusy else { return }
        guard model.modes.contains(where: { $0.cleanup != nil }) else {
            commandHotkey.reset()
            overlay.flashError("Command mode needs \"Clean up with AI\" on")
            return
        }

        do {
            try audio.beginRecording()
        } catch {
            Diag.log("could not start recording: \(error)")
            commandHotkey.reset()
            overlay.flashError(error.localizedDescription)
            return
        }
        overlay.modeName = "Command mode"
        overlay.show(.recording)
        armHandsFreeCap()

        Task { [overlay] in
            let selection = await Task.detached { SelectionReader.read() }.value
            await MainActor.run {
                guard self.commandHotkey.isRecording else { return }
                guard !selection.text.isEmpty else {
                    Diag.log("command mode: no selection found")
                    self.commandHotkey.reset()
                    self.audio.cancelRecording()
                    self.handsFreeCap?.cancel()
                    overlay.flashError("Select some text first")
                    return
                }
                Diag.log(
                    "command mode: \(selection.text.count) chars via \(selection.source.rawValue)")
                self.pendingSelection = selection.text
                overlay.show(.command(selectionChars: selection.text.count))
            }
        }
    }

    private func endCommand() {
        handsFreeCap?.cancel()
        let samples = audio.endRecording()
        guard let selection = pendingSelection else {
            overlay.hide()
            return
        }
        pendingSelection = nil

        guard samples.count > Int(sampleRate()) / 3 else {
            overlay.hide()
            return
        }

        overlay.show(.transcribing)
        isBusy = true

        Task { [engine, overlay] in
            let ctx = AppContext(
                bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                windowTitle: nil,
                surroundingText: nil,
                selectedText: selection
            )
            do {
                let result = try await engine.runCommand(samples: samples, ctx: ctx)
                await MainActor.run { self.finish(result) }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    Diag.log("command failed: \(error)")
                    overlay.flashError(Self.describe(error))
                }
            }
        }
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
        let bundleId = lastForegroundBundleId
        let mode = model.resolvedMode(bundleId: bundleId)
        overlay.modeName =
            model.modeMatchedApp(bundleId)
            ? "\(mode.name) · \(lastForegroundAppName ?? "this app")"
            : "\(mode.name) · fallback"
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
        pendingSelection = nil
        overlay.hide()
    }

    /// Hands-free has no key held down to bound it, so a forgotten session would
    /// record until memory ran out. Cap it and finish cleanly.
    private func armHandsFreeCap() {
        handsFreeCap?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let commandActive = self.commandHotkey.isRecording
            guard self.hotkey.isRecording || commandActive else { return }
            Diag.log("hit the \(Int(Self.maxRecordingSeconds))s recording cap; finishing")
            if commandActive {
                self.commandHotkey.reset()
                self.endCommand()
            } else {
                self.hotkey.reset()
                self.endDictation()
            }
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
            "mode \(result.modeName) (\(result.modeId)) | "
                + "inserted via \(method.rawValue): "
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

    static func describe(_ error: Error) -> String {
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
        // AppKit otherwise recomputes isEnabled from target/action validation,
        // which overrides the explicit disabling below.
        menu.autoenablesItems = false

        let sttProvider = model.modes.first?.stt.providerId ?? "groq"
        let ready =
            Permissions.microphoneGranted() && Permissions.accessibilityGranted()
            && model.hasKey(for: sttProvider)

        if ready {
            for line in [
                "Hold \(Settings.hotkey.displayName) to dictate",
                "Double-tap for hands-free, tap to finish",
                "Select text + hold \(Settings.commandHotkey.displayName) to edit it",
                "Escape while recording cancels",
            ] {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else {
            menu.addItem(withTitle: "Setup incomplete", action: nil, keyEquivalent: "")
        }

        if !Permissions.accessibilityGranted() {
            add(menu, "Grant Accessibility access…", #selector(openAccessibility))
        }
        if !Permissions.microphoneGranted() {
            add(menu, "Grant Microphone access…", #selector(openMicrophone))
        }
        if !model.hasKey(for: sttProvider) {
            add(menu, "Set up providers…", #selector(openSettings))
        }

        // Which mode will actually run, and why. Per-app matching is invisible
        // otherwise, and a mode silently not applying is hard to debug.
        menu.addItem(.separator())
        let bundleId = lastForegroundBundleId
        let effective = model.resolvedMode(bundleId: bundleId)
        let reason =
            model.modeMatchedApp(bundleId)
            ? "matches \(lastForegroundAppName ?? "this app")"
            : "fallback"
        let modeLine = NSMenuItem(
            title: "Mode: \(effective.name)  (\(reason))", action: nil, keyEquivalent: "")
        modeLine.isEnabled = false
        menu.addItem(modeLine)

        let modeMenu = NSMenu()
        for mode in model.modes {
            let item = NSMenuItem(
                title: mode.name, action: #selector(changeFallbackMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.state = mode.id == model.activeModeId ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Fallback Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        if let last = lastResult, !last.finalText.isEmpty {
            menu.addItem(.separator())
            let preview = String(last.finalText.prefix(48))
            let item = NSMenuItem(
                title: "Copy last: \"\(preview)…\"", action: #selector(copyLast),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let timing = NSMenuItem(
                title: "  \(last.modeName) · \(last.timings.totalMs) ms · \(last.sttModel)",
                action: nil, keyEquivalent: "")
            timing.isEnabled = false
            menu.addItem(timing)
        }

        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings))
        add(menu, "Open Log", #selector(openLog))
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

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Diag.url)
    }

    @objc private func changeFallbackMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.activeModeId = id
        refreshMenu()
    }

}
