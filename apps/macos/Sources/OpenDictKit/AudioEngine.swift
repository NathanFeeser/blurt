@preconcurrency import AVFoundation
import OpenDictCore

/// Microphone capture, resampled to what the core expects and pushed into the
/// core's ring buffer.
///
/// The engine is started on the hotkey and stopped the moment recording ends, so
/// macOS's orange microphone indicator is lit only while you are actually
/// dictating. An always-running engine would let the core's pre-roll window
/// catch words spoken a beat before the key registers, but it also means the app
/// permanently *looks* like it is listening, which is a worse trade for a tool
/// that lives in the menu bar all day.
///
/// To keep the start cheap, the graph is configured exactly once and only
/// `start()`/`stop()` are called per dictation — a full teardown and rebuild
/// each time would cost far more. Measured start latency is written to the diag
/// log so this stays honest.
final class AudioEngine {
    /// Owned by the Rust side; the shell only feeds it.
    let capture = AudioCapture()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false
    private var isConfigured = false

    /// Most recent RMS level, for the overlay meter.
    private(set) var level: Float = 0

    /// The device the graph is currently bound to, and what we think of it.
    /// Read by the UI so the microphone in use is never invisible — a silently
    /// switched input is the one failure that looks exactly like a bad model.
    private(set) var currentDevice: AudioInputDevice?
    private(set) var currentQuality: InputQuality = .fine

    var onLevel: ((Float) -> Void)?
    /// A recording was abandoned because the audio device changed underneath it.
    var onInterrupted: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    /// Build the graph. Idempotent, and separated from `start()` so the
    /// per-dictation path does as little work as possible.
    private func configure() throws {
        guard !isConfigured else { return }

        let input = engine.inputNode
        // Bind the device *before* reading the format: the format belongs to
        // whatever device the node is pointed at, and reading it first would
        // build a converter for the wrong one.
        bindInputDevice(input)
        let inputFormat = input.outputFormat(forBus: 0)

        // A zero sample rate means no usable input device — starting the engine
        // in that state throws deep inside CoreAudio with an opaque message.
        guard inputFormat.sampleRate > 0 else {
            throw AudioError.noInputDevice
        }

        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate()),
                channels: 1,
                interleaved: false
            ),
            let conv = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw AudioError.unsupportedFormat(inputFormat.description)
        }
        targetFormat = target
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buf, _ in
            self?.handle(buf)
        }

        engine.prepare()
        isConfigured = true
    }

    /// Point the input node at the user's chosen microphone.
    ///
    /// Without this the node follows the system default, which is how a pair of
    /// earbuds connecting can silently take over dictation. A pinned device that
    /// is not currently attached falls back to the default rather than failing —
    /// but says so, because recording from something you did not choose is
    /// exactly what this is here to prevent.
    private func bindInputDevice(_ input: AVAudioInputNode) {
        let devices = AudioDevices.inputDevices()
        let resolution = AudioDevices.resolve(
            preferredUID: Settings.inputDeviceUID, among: devices)

        var chosen: AudioInputDevice?
        switch resolution {
        case .systemDefault:
            chosen = AudioDevices.defaultInputDevice()
        case .pinned(let device):
            if let unit = input.audioUnit {
                var id = device.id
                let status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    Diag.log("could not bind \(device.name) (status \(status)); using the default")
                    chosen = AudioDevices.defaultInputDevice()
                } else {
                    chosen = device
                }
            }
        case .pinnedMissing(let uid):
            Diag.log("pinned microphone \(uid) is not attached; using the system default")
            chosen = AudioDevices.defaultInputDevice()
        }

        currentDevice = chosen
        currentQuality = chosen.map(AudioDevices.quality(of:)) ?? .fine
        if let chosen {
            // One line per graph build, for the same reason the hotkey logs
            // every press: the input device is invisible until it is written
            // down, and it determines more of the output quality than anything
            // else in the pipeline.
            Diag.log(
                "recording from \(chosen.name) at \(Int(chosen.sampleRate)) Hz "
                    + "(\(chosen.transport))"
                    + (currentQuality.warning.map { " — WARNING \($0)" } ?? ""))
        }
    }

    /// Warm the graph without opening the microphone. Called at launch so the
    /// first dictation of a session is not the slow one.
    func prewarm() {
        try? configure()
    }

    var running: Bool { isRunning }

    // MARK: - Recording control

    /// Opens the microphone and begins buffering. The orange indicator lights
    /// here and goes out in `endRecording()`/`cancelRecording()`.
    func beginRecording() throws {
        try configure()
        if !isRunning {
            let t0 = ProcessInfo.processInfo.systemUptime
            try engine.start()
            isRunning = true
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            Diag.log("audio engine started in \(ms)ms")
        }
        capture.start()
    }

    func cancelRecording() {
        capture.cancel()
        stopEngine()
    }

    func endRecording() -> [Float] {
        let samples = capture.stop()
        stopEngine()
        return samples
    }

    /// Releases the microphone. The graph stays configured for the next press.
    ///
    /// Clearing the capture buffer here is not optional: the core's pre-roll
    /// ring would otherwise still hold the tail of this dictation, and seed the
    /// next one with it. The core also guards against this by age, but a shell
    /// that closes the microphone should say so rather than rely on a timeout.
    private func stopEngine() {
        guard isRunning else { return }
        engine.stop()
        capture.reset()
        isRunning = false
        level = 0
    }

    /// Drop the graph so the next press rebuilds it against a different device.
    /// Called when the user picks a different microphone.
    func invalidateDevice() {
        guard isConfigured else { return }
        stopEngine()
        engine.inputNode.removeTap(onBus: 0)
        isConfigured = false
        converter = nil
        targetFormat = nil
    }

    /// Full teardown, for app exit.
    func shutdown() {
        stopEngine()
        if isConfigured {
            engine.inputNode.removeTap(onBus: 0)
            isConfigured = false
        }
    }

    // MARK: - Private

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var error: NSError?
        // AVAudioConverter invokes this block synchronously on the calling
        // thread, so the shared flag is safe despite the @Sendable signature.
        nonisolated(unsafe) var supplied = false
        converter.convert(to: out, error: &error) { _, status in
            // The converter asks repeatedly; hand over this buffer exactly once,
            // then report that nothing more is available for this call.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else {
            return
        }

        let frames = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        // The one place audio crosses into Rust. Chunk-level, ~40-90 calls/sec.
        let rms = capture.push(frames: frames)
        level = rms
        onLevel?(rms)
    }

    /// Fires when the user changes input device, unplugs headphones, or the
    /// machine wakes. The tap and converter are bound to the old format, so both
    /// have to be rebuilt or capture silently produces nothing.
    @objc private func configurationChanged() {
        // The tap and converter are bound to the old format, so both must be
        // rebuilt. Doing it lazily means a device change between dictations
        // costs nothing until the next press.
        let wasRecording = isRunning
        stopEngine()
        engine.inputNode.removeTap(onBus: 0)
        isConfigured = false
        converter = nil
        targetFormat = nil
        Diag.log("audio device changed; graph will rebuild on next use")

        if wasRecording {
            // A device change mid-dictation loses the tail of the audio; there
            // is no good recovery, so drop it rather than transcribe a fragment.
            capture.cancel()
            onInterrupted?()
        }
    }
}

enum AudioError: LocalizedError {
    case noInputDevice
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available. Check Sound settings in System Settings."
        case .unsupportedFormat(let f):
            return "This microphone's format isn't supported: \(f)"
        }
    }
}
