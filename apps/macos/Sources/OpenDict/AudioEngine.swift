@preconcurrency import AVFoundation
import OpenDictCore

/// Microphone capture, resampled to what the core expects and pushed into its
/// ring buffer.
///
/// The engine runs continuously rather than starting on the hotkey, for two
/// reasons: `AVAudioEngine.start()` costs 100-300 ms, which would clip the first
/// word worse than having no pre-roll at all; and a continuously fed ring buffer
/// is the only way the core's pre-roll window can contain anything.
///
/// The cost is that macOS shows the orange microphone indicator whenever the app
/// is running. That is a real tradeoff, not an oversight — "Pause Microphone" in
/// the menu stops the engine for users who would rather have the indicator off.
final class AudioEngine {
    /// Owned by the Rust side; the shell only feeds it.
    let capture = AudioCapture()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false

    /// Most recent RMS level, for the overlay meter.
    private(set) var level: Float = 0

    var onLevel: ((Float) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
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
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
    }

    var running: Bool { isRunning }

    // MARK: - Recording control (delegates to the core's ring buffer)

    func beginRecording() { capture.start() }
    func cancelRecording() { capture.cancel() }
    func endRecording() -> [Float] { capture.stop() }

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
        guard isRunning else { return }
        stop()
        do {
            try start()
        } catch {
            NSLog("OpenDict: could not restart audio after a device change: \(error)")
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
