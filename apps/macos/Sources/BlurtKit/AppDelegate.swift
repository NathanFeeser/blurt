import AppKit
import BlurtCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = DictationEngine()
    private lazy var model = AppModel(engine: engine)
    private lazy var settingsWindow = SettingsWindow(model: model)
    private lazy var onboardingWindow = OnboardingWindow(model: model)
    private let audio = AudioEngine()
    private let hotkey = HotkeyMonitor()
    private let commandHotkey = HotkeyMonitor()
    private let overlay = RecordingOverlay()

    private var statusItem: NSStatusItem!
    private var lastResult: DictationResult?
    /// What was last put into another app, so it can be taken back out.
    /// Cleared once undone — undoing twice would eat text we never wrote.
    private var lastInsertion: TextInserter.Insertion?
    private var isBusy = false
    private var handsFreeCap: DispatchWorkItem?
    /// Releases the hotkey if a transcription never returns. See `beginBusy`.
    private var busyWatchdog: DispatchWorkItem?
    /// The device we have already warned about, so the warning appears once.
    private var warnedAboutDeviceUID: String?
    /// Bumped whenever a transcription is abandoned, so a result that arrives
    /// afterwards can recognise that nobody is waiting for it any more.
    private var dictationGeneration = 0
    /// The selection captured when command mode started. Held because the user
    /// may click elsewhere while speaking, and the instruction applies to what
    /// was selected at the moment they pressed the key.
    private var pendingSelection: String?

    /// The last app that was frontmost other than Blurt itself.
    ///
    /// `NSWorkspace.frontmostApplication` can report Blurt once its own menu
    /// or settings window takes focus, which would make the menu claim the
    /// fallback mode was active no matter which app the user was really in.
    private var lastForegroundBundleId: String?
    private var lastForegroundAppName: String?

    /// Ten minutes of 16 kHz mono is ~38 MB — generous for a long hands-free
    /// dictation, and a hard stop against one left running by accident.
    private static let maxRecordingSeconds: TimeInterval = 600

    /// How long a transcription may run before the hotkey is handed back.
    ///
    /// The HTTP client self-limits at 30 s, but the on-device path has no
    /// timeout at all: a wedged WhisperKit call would strand `isBusy` and take
    /// the hotkey down with it for the rest of the session, which is
    /// indistinguishable from a dead hotkey. Generous enough to clear a cold
    /// model load (~8 s) plus a long dictation, and still bounded.
    private static let transcriptionTimeout: TimeInterval = 60

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.log("applicationDidFinishLaunching")
        Settings.registerDefaults()
        // Before anything can open a window: without this the settings window's
        // text fields ignore ⌘V. See MainMenu.
        MainMenu.install(on: NSApp)
        NotificationCenter.default.addObserver(
            forName: .blurtHotkeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotkey.key = Settings.hotkey
                self.commandHotkey.key = Settings.commandHotkey
                self.refreshMenu()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .blurtInputDeviceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Drop the graph so the next press rebuilds against the newly
                // chosen device, and let the warning fire again for it.
                self.audio.invalidateDevice()
                self.warnedAboutDeviceUID = nil
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
        AudioDevices.startWatchingDevices()
        buildStatusItem()
        applySettingsToEngine()
        wireHotkey()

        Task { await startUp() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        commandHotkey.stop()
        hotkey.stop()
        audio.shutdown()
    }

    // MARK: - Start-up

    private func startUp() async {
        Diag.log("startUp begin; mic status=\(Permissions.statusDescription())")

        // When the setup flow is about to appear, the permission prompts are
        // its job rather than ours. Firing them from here first is exactly how
        // you get a denial: a dialog asking to read every app you use, with no
        // explanation in front of it, is one people say no to — and macOS never
        // asks a second time.
        if OnboardingModel.shouldPresentAtLaunch(in: .live(model: model)) {
            Diag.log("setup incomplete; presenting the first-run flow")
            onboardingWindow.onFinish = { [weak self] in
                guard let self else { return }
                Task { await self.enableDictation() }
            }
            onboardingWindow.show()
            refreshMenu()
            return
        }

        await enableDictation()
    }

    /// Everything that needs the permissions to already be in place. Split out
    /// of `startUp` so the setup flow can call it once it has collected them.
    private func enableDictation() async {
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

    /// Write down what the core's speech check saw.
    ///
    /// Logged on every dictation, not only the rejected ones, because the
    /// interesting number is where real speech from *this* microphone sits
    /// relative to the threshold — and that is unknowable from the failures
    /// alone. A take dropped for "no speech" with nothing in the log behind it
    /// is indistinguishable from a dictation that vanished, which is precisely
    /// the class of silent failure this file's log exists to prevent.
    private func logSpeechMeasurement(_ samples: [Float]) {
        let t0 = ProcessInfo.processInfo.systemUptime
        let m = measureSpeech(samples: samples)
        let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        // The pitch half only runs when the loudness half said no, so its cost
        // is worth watching: it sits on the path between releasing the key and
        // seeing text.
        let pitch =
            m.pitchChecked
            ? " voiced=\(m.voicedFrames) variety=\(String(format: "%.2f", m.pitchVariety))"
            : " (pitch not needed)"
        Diag.log(
            "speech check: \(m.hasSpeech ? "speech" : "NO SPEECH") "
                + "room=\(String(format: "%.5f", m.room)) "
                + "loud=\(String(format: "%.5f", m.loud)) "
                + "ratio=\(String(format: "%.1f", m.ratio)) "
                + "frames=\(m.frames)" + pitch + " in \(ms)ms")
    }

    /// Short label for where transcription happens.
    static func sttLabel(_ mode: Mode) -> String {
        switch mode.stt.providerId {
        case "local", "whisperkit", "on-device": return "on-device"
        default: return mode.stt.providerId
        }
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
        let generation = beginBusy()

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
                await MainActor.run { self.finish(result, generation: generation) }
            } catch {
                await MainActor.run {
                    guard self.isCurrent(generation) else { return }
                    self.endBusy()
                    Diag.log("command failed: \(error)")
                    overlay.flashError(Self.describe(error))
                }
            }
        }
    }

    // MARK: - The busy flag

    /// Claim the pipeline, and arm the watchdog that gives it back.
    ///
    /// Returns the generation this attempt belongs to. A result carrying a stale
    /// generation is dropped rather than inserted: text pasted a minute late
    /// lands in whatever the user has moved on to, which is worse than losing it.
    private func beginBusy() -> Int {
        isBusy = true
        dictationGeneration += 1
        let generation = dictationGeneration

        busyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isBusy, self.dictationGeneration == generation else { return }
            Diag.log(
                "transcription did not return within \(Int(Self.transcriptionTimeout))s; "
                    + "releasing the hotkey")
            // Bumping the generation is what makes the abandonment stick.
            self.dictationGeneration += 1
            self.isBusy = false
            self.overlay.flashError("Transcription timed out")
        }
        busyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transcriptionTimeout, execute: work)
        return generation
    }

    private func endBusy() {
        busyWatchdog?.cancel()
        busyWatchdog = nil
        isBusy = false
    }

    /// Whether a result that just arrived is still the one being waited on.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == dictationGeneration
    }

    // MARK: - Dictation flow

    private func beginDictation() {
        guard !isBusy else {
            // Silently ignoring the key here is indistinguishable from a dead
            // hotkey, and a transcription that never returns would strand this
            // flag and take the hotkey down with it.
            Diag.log("hotkey pressed while the previous dictation is still in flight; ignoring")
            return
        }
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
        let where_ =
            model.modeMatchedApp(bundleId)
            ? (lastForegroundAppName ?? "this app") : "fallback"
        // Naming the provider is the whole point: "on-device" is a promise about
        // where the audio goes, and the user needs to see it kept. The
        // microphone is here for the opposite reason: it is the input that
        // determines the most and announces itself the least.
        let mic = audio.currentDevice.map { " · \($0.name)" } ?? ""
        let warn = audio.currentQuality.warning == nil ? "" : " ⚠︎"
        overlay.modeName = "\(mode.name) · \(where_) · \(Self.sttLabel(mode))\(mic)\(warn)"
        overlay.show(.recording)
        armHandsFreeCap()
    }

    /// Tell the user once when they are dictating through a microphone that
    /// will not do them any favours.
    ///
    /// Once per device, not once per dictation: a warning on every press is
    /// noise, and noise gets ignored precisely when it matters.
    private func warnAboutMicrophoneIfNeeded() {
        guard let why = audio.currentQuality.warning, let device = audio.currentDevice else {
            return
        }
        guard warnedAboutDeviceUID != device.uid else { return }
        warnedAboutDeviceUID = device.uid
        Diag.log("degraded microphone: \(why)")
        overlay.flashError(why, seconds: 5)
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
        logSpeechMeasurement(samples)

        overlay.show(.transcribing)
        let generation = beginBusy()

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
                    self.finish(result, generation: generation)
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrent(generation) else { return }
                    self.endBusy()
                    Diag.log("transcription failed: \(error)")
                    overlay.flashError(Self.describe(error))
                }
            }
        }
    }

    private func finish(_ result: DictationResult, generation: Int) {
        // The watchdog already gave up on this one and the user has moved on.
        // Inserting now would paste into whatever they are doing instead.
        guard isCurrent(generation) else {
            Diag.log("dropped a transcription that arrived after the timeout")
            return
        }
        endBusy()
        lastResult = result
        overlay.hide()

        guard !result.finalText.isEmpty else {
            // Logged because otherwise a dictation into silence leaves no trace
            // at all, which reads exactly like a dictation that vanished.
            Diag.log("transcribed to nothing; inserting nothing")
            overlay.flashError("Nothing was said")
            return
        }

        let method = TextInserter.insert(
            result.finalText,
            preferAccessibility: Settings.preferAccessibilityInsert
        )
        lastInsertion = TextInserter.Insertion(
            text: result.finalText,
            bundleId: lastForegroundBundleId,
            at: Date(),
            entryId: result.entryId
        )
        // The setup flow's last step waits on this: a transcription that
        // actually landed somewhere is the only proof the chain works.
        NotificationCenter.default.post(name: .blurtDictationCompleted, object: nil)
        // Which strategy landed is only knowable here, and it is the first thing
        // worth looking at when someone reports text going into the wrong place.
        if let entryId = result.entryId {
            try? engine.historyNoteInsertion(id: entryId, method: method.rawValue)
            model.noteHistoryChanged()
        }
        Diag.log(
            "mode \(result.modeName) (\(result.modeId)) via "
                + "\(result.sttProvider)/\(result.sttModel) | "
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

        warnAboutMicrophoneIfNeeded()

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
            systemSymbolName: "waveform", accessibilityDescription: "Blurt")
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

        if let device = audio.currentDevice {
            let warning = audio.currentQuality.warning == nil ? "" : "  ⚠︎ poor for dictation"
            let micLine = NSMenuItem(
                title: "Mic: \(device.name)\(warning)", action: nil, keyEquivalent: "")
            micLine.isEnabled = false
            menu.addItem(micLine)
        }

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
                title: "  \(last.modeName) · \(last.sttProvider) · \(last.timings.totalMs) ms",
                action: nil, keyEquivalent: "")
            timing.isEnabled = false
            menu.addItem(timing)
        }

        if let insertion = lastInsertion {
            let item = NSMenuItem(
                title: "Undo \"\(String(insertion.text.prefix(32)))…\"",
                action: #selector(undoLastInsertion), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let recent = model.historyEnabled ? model.historyRecent(limit: 5) : []
        if !recent.isEmpty {
            let historyMenu = NSMenu()
            for entry in recent {
                let item = NSMenuItem(
                    title: Self.menuPreview(entry.finalText),
                    action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.finalText
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let all = NSMenuItem(title: "Show All…", action: #selector(openHistory), keyEquivalent: "")
            all.target = self
            historyMenu.addItem(all)

            let historyItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            historyItem.submenu = historyMenu
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())
        add(menu, "Set Up Blurt…", #selector(openOnboarding))
        add(menu, "Settings…", #selector(openSettings))
        add(menu, "Open Log", #selector(openLog))
        menu.addItem(.separator())
        add(menu, "Quit Blurt", #selector(NSApplication.terminate(_:)), target: NSApp)

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

    @objc private func openOnboarding() { onboardingWindow.show() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openMicrophone() { Permissions.openMicrophoneSettings() }

    @objc private func copyLast() {
        guard let text = lastResult?.finalText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One line of a menu item: newlines would otherwise render as spaces and
    /// make a multi-paragraph dictation an unreadably long row.
    static func menuPreview(_ text: String, limit: Int = 48) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count <= limit
            ? flattened
            : String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc private func undoLastInsertion() {
        guard let insertion = lastInsertion else { return }
        // Let the menu finish closing and focus return to the app we typed
        // into. Acting immediately would aim the keystroke at a closing menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let outcome = TextInserter.undo(
                insertion, frontmostBundleId: self.lastForegroundBundleId)
            switch outcome {
            case .removed, .sentUndoKeystroke:
                // Success is visible on screen; saying so would be noise.
                self.lastInsertion = nil
                Diag.log("undo: \(outcome)")
            case .refused(let why):
                Diag.log("undo refused: \(why)")
                self.overlay.flashError(why)
            }
            self.refreshMenu()
        }
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openHistory() {
        settingsWindow.show(tab: .history)
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
