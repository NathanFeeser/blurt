import CoreAudio
import Foundation

/// One microphone the system can offer us.
struct AudioInputDevice: Identifiable, Equatable {
    /// How the device is attached. This, not the sample rate, is what predicts
    /// whether dictation will be any good.
    enum Transport: Equatable {
        case builtIn
        case bluetooth
        case usb
        case hdmi
        case virtual
        case other
    }

    let id: AudioDeviceID
    /// Stable across reboots and reconnections, unlike `id`. This is what gets
    /// persisted when the user pins a device.
    let uid: String
    let name: String
    let sampleRate: Double
    let transport: Transport
}

/// Whether this microphone is one to dictate through.
enum InputQuality: Equatable {
    case fine
    /// Usable, but the transcription will suffer, with the reason to show.
    case degraded(String)

    var warning: String? {
        if case .degraded(let why) = self { return why }
        return nil
    }
}

/// What the app should actually record from, given the user's preference.
enum InputResolution: Equatable {
    /// No preference: follow whatever the system calls the default input.
    case systemDefault
    case pinned(AudioInputDevice)
    /// A device was pinned but is not currently attached. Falls back to the
    /// system default, and the caller says so rather than silently recording
    /// from something else — silently recording from something else is the
    /// entire bug this feature exists to prevent.
    case pinnedMissing(uid: String)
}

enum AudioDevices {

    // MARK: - The rules
    //
    // Pure, and tested. Everything below them is CoreAudio plumbing.

    /// Judge a microphone before it ruins a dictation.
    ///
    /// The rate is the whole rule, and it deliberately does not care about the
    /// transport. Bluetooth used to be flagged outright, on the theory that
    /// hands-free mode is narrowband — but that is only true of HFP's older
    /// CVSD codec at 8 kHz. Any modern headset negotiates mSBC at 16 kHz, which
    /// is *exactly* the rate transcription runs at, and flagging it warned
    /// people away from a microphone that was performing at full fidelity.
    ///
    /// Judging the rate instead also covers the cheap USB microphone that
    /// captures at 8 kHz, which is just as bad and used to sail through.
    ///
    /// What is left of the Bluetooth concern is real but not a property of the
    /// device: HFP loses packets on a congested 2.4 GHz band, and some headsets
    /// gate quiet consonants away. Both are intermittent and situational, which
    /// makes them a bad fit for a permanent banner.
    static func quality(of device: AudioInputDevice) -> InputQuality {
        // 16 kHz is exactly what transcription wants, so it is not itself a
        // problem — below that, the words are simply not in the signal.
        if device.sampleRate > 0, device.sampleRate < 16000 {
            return .degraded(
                "\(device.name) captures at \(Int(device.sampleRate)) Hz, below the 16 kHz "
                    + "transcription needs.")
        }
        return .fine
    }

    static func resolve(preferredUID: String?, among devices: [AudioInputDevice])
        -> InputResolution
    {
        guard let preferredUID, !preferredUID.isEmpty else { return .systemDefault }
        guard let match = devices.first(where: { $0.uid == preferredUID }) else {
            return .pinnedMissing(uid: preferredUID)
        }
        return .pinned(match)
    }

    // MARK: - CoreAudio

    /// Start reporting when microphones come and go, as
    /// `.blurtAudioDevicesChanged`.
    ///
    /// Called once at launch. Without it, any list of microphones on screen is
    /// whatever was attached when it was first drawn: the settings window is
    /// built once and reused, so its `onAppear` runs exactly once per launch,
    /// and a headset connected afterwards never appears in the picker at all.
    /// The default-input selector is watched alongside the device list because
    /// the warning shown under the picker describes whichever microphone would
    /// actually be used, and that moves without any device coming or going.
    static func startWatchingDevices() {
        for selector in [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            // The block captures nothing and only posts: enumeration happens on
            // the main thread, in whoever is displaying the list.
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { _, _ in
                NotificationCenter.default.post(name: .blurtAudioDevicesChanged, object: nil)
            }
            if status != noErr {
                Diag.log("could not watch audio devices (selector \(selector), status \(status))")
            }
        }
    }

    /// Whether the graph has to be torn down because the microphone it is bound
    /// to is no longer the one we want.
    ///
    /// Checked before every recording rather than waiting for a configuration
    /// notification. Changing the system default input does not reliably rebuild
    /// an already-built graph, so an app that only reacts to notifications keeps
    /// recording from the old device long after the user moved the default.
    static func shouldRebuild(bound: AudioDeviceID?, desired: AudioDeviceID?) -> Bool {
        guard let bound, let desired else { return false }
        return bound != desired
    }

    /// Describe a device by id. Used to report what the input node is *actually*
    /// bound to, rather than what it was asked to bind to.
    static func device(withID id: AudioDeviceID) -> AudioInputDevice? {
        describe(id)
    }

    /// Every device that can currently record.
    static func inputDevices() -> [AudioInputDevice] {
        deviceIDs()
            .filter { inputChannelCount($0) > 0 }
            .compactMap { describe($0) }
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return describe(deviceID)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            sampleRate: nominalSampleRate(id),
            transport: transport(id)
        )
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // CoreAudio hands back a +1 retained CFStringRef for these properties, so
        // it arrives as an Unmanaged and is released here. Taking `&value` on a
        // plain CFString instead compiles, works, and leaks a string per call.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return Double(rate)
    }

    private static func transport(_ id: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return .other
        }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        // Both Bluetooth transports degrade the same way once the mic opens.
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }
}

extension Notification.Name {
    /// The set of attached audio devices, or which one is the system default,
    /// changed. Posted by `AudioDevices.startWatchingDevices()`.
    static let blurtAudioDevicesChanged = Notification.Name("blurtAudioDevicesChanged")
}
