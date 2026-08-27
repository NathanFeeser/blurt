@preconcurrency import AVFoundation
import AudioToolbox
import BlurtCore
import CoreAudio

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
/// Capture goes through an AUHAL audio unit rather than `AVAudioEngine`, and the
/// reason is not preference. `AVAudioEngine.inputNode` cannot be pointed at a
/// device: setting `kAudioOutputUnitProperty_CurrentDevice` on it returns
/// `noErr` and changes nothing, so pinning a microphone that was not already the
/// system default recorded silence while the UI named the pinned one. Worse, its
/// input format is latched per *process* — change the system default while the
/// app is running and even a brand new `AVAudioEngine` keeps reporting the old
/// format and captures nothing, and installing a tap on that stale format throws
/// an Objective-C exception that Swift cannot catch. An AUHAL unit takes its
/// device before `AudioUnitInitialize`, which is the whole difference: measured
/// on a non-default microphone it reports the real hardware format and captures
/// continuously, and it can be re-pointed at a different device any number of
/// times within one process.
///
/// The unit is built once per device and only started and stopped per dictation,
/// so the hotkey path stays cheap. Measured start latency is written to the diag
/// log so this stays honest.
final class AudioEngine: @unchecked Sendable {
    /// Owned by the Rust side; the shell only feeds it.
    let capture = AudioCapture()

    private var unit: AudioUnit?
    /// Scratch the render callback hands to `AudioUnitRender`. Allocated once
    /// per graph, because the callback runs on a real-time thread.
    private var renderBuffer: UnsafeMutableAudioBufferListPointer?
    private var hardwareFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// What the converter always outputs: the core's format, fixed for the life
    /// of the app. The hardware format moves; this must not, because it is what
    /// the Rust side accumulates.
    private let targetFormat: AVAudioFormat

    private var isRunning = false
    private var isConfigured = false
    /// The device the unit is bound to, read back from the unit rather than
    /// remembered from what we asked for.
    private var boundDeviceID: AudioDeviceID?

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
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate()),
                channels: 1,
                interleaved: false
            )
        else {
            // 16 kHz mono float is not a format CoreAudio can refuse. If it
            // ever did, nothing downstream could work, and failing here is far
            // easier to diagnose than an empty recording.
            preconditionFailure("could not build the core's audio format")
        }
        targetFormat = target
    }

    // MARK: - The graph

    /// Build the unit against the microphone we should be recording from.
    /// Idempotent, and separated from `start()` so the per-dictation path does
    /// as little work as possible.
    private func configure() throws {
        guard !isConfigured else { return }

        let device = desiredDevice(loggingProblems: true)
        guard let device else { throw AudioError.noInputDevice }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioError.noInputDevice
        }
        var new: AudioUnit?
        try check(AudioComponentInstanceNew(component, &new), "creating the audio unit")
        guard let new else { throw AudioError.noInputDevice }
        unit = new

        // Bus 1 is input, bus 0 is output. A capture-only unit wants the first
        // and must explicitly refuse the second.
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                new, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4),
            "enabling input")
        try check(
            AudioUnitSetProperty(
                new, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4),
            "disabling output")

        // Before `AudioUnitInitialize`, which is the entire reason this is an
        // AUHAL unit and not an AVAudioEngine.
        var id = device.id
        try check(
            AudioUnitSetProperty(
                new, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4),
            "binding \(device.name)")

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                new, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size),
            "reading the hardware format")
        // A zero sample rate means no usable input device — initialising in that
        // state fails deep inside CoreAudio with an opaque message.
        guard hardware.mSampleRate > 0 else { throw AudioError.noInputDevice }

        // What we want handed to us: mono float, at the hardware's rate. The
        // resample to the core's rate is done by the converter rather than by
        // the unit — asking the unit for 16 kHz on 48 kHz hardware still
        // delivers hardware-rate frame counts, which desynchronises everything
        // downstream.
        var client = AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(
            AudioUnitSetProperty(
                new, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "setting the client format")

        guard
            let hardwareFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.mSampleRate,
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
        else {
            throw AudioError.unsupportedFormat("\(Int(hardware.mSampleRate)) Hz")
        }
        self.hardwareFormat = hardwareFormat
        self.converter = converter

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: Self.renderBufferBytes,
            mData: malloc(Int(Self.renderBufferBytes)))
        renderBuffer = list

        var callback = AURenderCallbackStruct(
            inputProc: renderInput,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(
            AudioUnitSetProperty(
                new, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "installing the render callback")
        try check(AudioUnitInitialize(new), "initialising the audio unit")

        // Report what the unit is bound to, not what it was asked to bind to.
        // Those two can disagree, and a UI that names a microphone the app is
        // not recording from is worse than one that names none at all — it
        // sends you looking for the problem somewhere else entirely.
        let actual = Self.boundDevice(new).flatMap(AudioDevices.device(withID:)) ?? device
        boundDeviceID = actual.id
        currentDevice = actual
        currentQuality = AudioDevices.quality(of: actual)
        isConfigured = true

        // One line per graph build, for the same reason the hotkey logs every
        // press: the input device is invisible until it is written down, and it
        // determines more of the output quality than anything else in the
        // pipeline.
        Diag.log(
            "recording from \(actual.name) at \(Int(hardware.mSampleRate)) Hz "
                + "(\(actual.transport))"
                + (currentQuality.warning.map { " — WARNING \($0)" } ?? ""))
    }

    /// The microphone that should be recording right now.
    private func desiredDevice(loggingProblems: Bool = false) -> AudioInputDevice? {
        // No preference needs no enumeration — two property reads instead of a
        // sweep of every device, on the hotkey path.
        guard let preferred = Settings.inputDeviceUID else {
            return AudioDevices.defaultInputDevice()
        }
        switch AudioDevices.resolve(preferredUID: preferred, among: AudioDevices.inputDevices()) {
        case .pinned(let device):
            return device
        case .pinnedMissing(let uid):
            if loggingProblems {
                Diag.log("pinned microphone \(uid) is not attached; using the system default")
            }
            return AudioDevices.defaultInputDevice()
        case .systemDefault:
            return AudioDevices.defaultInputDevice()
        }
    }

    private static func boundDevice(_ unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != 0 ? id : nil
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
        // Re-check the device on every press rather than trusting a
        // notification. The system default moves without ceremony, and the
        // failure mode is silent: the old microphone keeps recording while
        // everything reports the new one.
        if isConfigured, boundDeviceID != desiredDevice()?.id {
            Diag.log("input device changed since the graph was built; rebuilding")
            invalidateDevice()
        }
        try configure()
        if !isRunning, let unit {
            let t0 = ProcessInfo.processInfo.systemUptime
            try check(AudioOutputUnitStart(unit), "starting capture")
            isRunning = true
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            Diag.log("audio unit started in \(ms)ms")
        }
        capture.start()
    }

    func cancelRecording() {
        capture.cancel()
        stopUnit()
    }

    func endRecording() -> [Float] {
        let samples = capture.stop()
        stopUnit()
        return samples
    }

    /// Releases the microphone. The unit stays built for the next press.
    ///
    /// Clearing the capture buffer here is not optional: the core's pre-roll
    /// ring would otherwise still hold the tail of this dictation, and seed the
    /// next one with it. The core also guards against this by age, but a shell
    /// that closes the microphone should say so rather than rely on a timeout.
    private func stopUnit() {
        guard isRunning else { return }
        if let unit { AudioOutputUnitStop(unit) }
        capture.reset()
        isRunning = false
        level = 0
    }

    /// Drop the graph so the next press rebuilds it against a different device.
    /// Called when the user picks a different microphone, and whenever the
    /// device we are bound to is no longer the one we want.
    func invalidateDevice() {
        stopUnit()
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let renderBuffer {
            free(renderBuffer[0].mData)
            free(renderBuffer.unsafeMutablePointer)
        }
        renderBuffer = nil
        converter = nil
        hardwareFormat = nil
        boundDeviceID = nil
        isConfigured = false
    }

    /// Full teardown, for app exit.
    func shutdown() {
        invalidateDevice()
    }

    // MARK: - Private

    /// Room for one render's worth of frames. Buffers arrive in slices of about
    /// 512–4096 frames; 16384 mono floats is generous headroom.
    private static let renderBufferBytes: UInt32 = 65536

    /// Called on the audio unit's real-time thread.
    fileprivate func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard let unit, let renderBuffer, let hardwareFormat, let converter else { return noErr }
        guard frames * 4 <= Self.renderBufferBytes else { return noErr }

        renderBuffer[0].mDataByteSize = frames * 4
        let status = AudioUnitRender(
            unit, flags, timestamp, bus, frames, renderBuffer.unsafeMutablePointer)
        guard status == noErr, let raw = renderBuffer[0].mData else { return status }

        guard let input = AVAudioPCMBuffer(pcmFormat: hardwareFormat, frameCapacity: frames),
            let destination = input.floatChannelData?[0]
        else { return noErr }
        input.frameLength = frames
        memcpy(destination, raw, Int(frames) * 4)

        let ratio = targetFormat.sampleRate / hardwareFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return noErr
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
            return input
        }

        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else {
            return noErr
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        // The one place audio crosses into Rust. Chunk-level, ~40-90 calls/sec.
        let rms = capture.push(frames: samples)
        level = rms
        onLevel?(rms)
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        Diag.log("\(what) failed with status \(status)")
        throw AudioError.coreAudio(what, status)
    }
}

/// The AUHAL input callback. A C function pointer, so the instance travels in
/// `inputProcRefCon` rather than being captured.
private let renderInput: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
        .render(flags, timestamp, bus, frames)
}

enum AudioError: LocalizedError {
    case noInputDevice
    case unsupportedFormat(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available. Check Sound settings in System Settings."
        case .unsupportedFormat(let f):
            return "This microphone's format isn't supported: \(f)"
        case .coreAudio(let what, let status):
            return "The microphone could not be opened (\(what), error \(status))."
        }
    }
}
