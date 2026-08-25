import Foundation
import Testing

@testable import OpenDictKit

private func device(
    _ name: String = "MacBook Pro Microphone",
    uid: String = "BuiltInMicrophoneDevice",
    rate: Double = 48000,
    transport: AudioInputDevice.Transport = .builtIn
) -> AudioInputDevice {
    AudioInputDevice(id: 1, uid: uid, name: name, sampleRate: rate, transport: transport)
}

/// The rule that would have caught a morning of debugging: earbuds connected,
/// the system default moved to their narrowband mic, and every transcript came
/// back with holes in it while the app said nothing.
@Suite("Microphone quality")
struct InputQualityTests {

    @Test("Bluetooth microphones are flagged")
    func bluetoothIsFlagged() {
        let earbuds = device("Nothing Ear (a)", rate: 16000, transport: .bluetooth)
        #expect(AudioDevices.quality(of: earbuds).warning != nil)
        #expect(AudioDevices.quality(of: earbuds).warning?.contains("Nothing Ear (a)") == true)
    }

    @Test("Bluetooth is flagged on its transport, not its sample rate")
    func bluetoothFlaggedEvenAtAHealthyRate() {
        // The damage is the hands-free codec and its noise gate, so a Bluetooth
        // device advertising a fine rate is still a bad idea.
        let headset = device("Some Headset", rate: 48000, transport: .bluetooth)
        #expect(AudioDevices.quality(of: headset).warning != nil)
    }

    @Test("The built-in microphone is fine")
    func builtInIsFine() {
        #expect(AudioDevices.quality(of: device()) == .fine)
    }

    @Test("A wired 16 kHz microphone is fine")
    func sixteenKilohertzWiredIsFine() {
        // 16 kHz is exactly what transcription wants. Flagging it would train
        // the user to ignore the warning.
        let usb = device("USB Mic", rate: 16000, transport: .usb)
        #expect(AudioDevices.quality(of: usb) == .fine)
    }

    @Test("Below 16 kHz is flagged")
    func narrowbandIsFlagged() {
        let telephone = device("Old Headset", rate: 8000, transport: .usb)
        #expect(AudioDevices.quality(of: telephone).warning != nil)
    }

    @Test("An unknown sample rate is not treated as a bad one")
    func zeroRateIsNotFlagged() {
        // CoreAudio returns 0 when it will not answer. That is missing data,
        // not a slow microphone.
        #expect(AudioDevices.quality(of: device(rate: 0, transport: .usb)) == .fine)
    }
}

/// The bug this exists to prevent, reported from real use: the system default
/// input was changed to a different microphone and the app went on recording
/// from the old one, because the graph had already been built and nothing
/// rebuilt it.
@Suite("Rebinding")
struct RebuildTests {

    @Test("A changed device forces a rebuild")
    func changedDeviceRebuilds() {
        #expect(AudioDevices.shouldRebuild(bound: 41, desired: 77))
    }

    @Test("The same device does not")
    func sameDeviceDoesNotRebuild() {
        // The check runs on every press, so a false positive would tear down
        // and rebuild the graph before every dictation.
        #expect(!AudioDevices.shouldRebuild(bound: 41, desired: 41))
    }

    @Test("An unbuilt graph is not a rebuild")
    func unboundNeedsNoRebuild() {
        #expect(!AudioDevices.shouldRebuild(bound: nil, desired: 77))
    }

    @Test("No available device leaves the graph alone")
    func noDesiredDeviceLeavesItAlone() {
        // Nothing to switch to. Tearing down what works in favour of nothing
        // would turn "no default input right now" into a broken hotkey.
        #expect(!AudioDevices.shouldRebuild(bound: 41, desired: nil))
    }
}

@Suite("Microphone selection")
struct InputResolutionTests {
    private let builtIn = device()
    private let earbuds = device("Nothing Ear (a)", uid: "bt-uid", rate: 16000, transport: .bluetooth)

    @Test("No preference follows the system default")
    func noPreferenceFollowsSystem() {
        #expect(AudioDevices.resolve(preferredUID: nil, among: [builtIn]) == .systemDefault)
        #expect(AudioDevices.resolve(preferredUID: "", among: [builtIn]) == .systemDefault)
    }

    @Test("A pinned device wins over whatever the system default is")
    func pinnedDeviceWins() {
        // The whole point: earbuds connecting moves the system default, and
        // dictation should stay where it was put.
        let resolution = AudioDevices.resolve(
            preferredUID: builtIn.uid, among: [earbuds, builtIn])
        #expect(resolution == .pinned(builtIn))
    }

    @Test("A pinned device that is unplugged is reported, not silently swapped")
    func missingPinnedDeviceIsReported() {
        // Falling back is right; doing it quietly is not — recording from a
        // device you did not choose is the failure this whole feature exists
        // to prevent.
        let resolution = AudioDevices.resolve(preferredUID: "gone", among: [earbuds])
        #expect(resolution == .pinnedMissing(uid: "gone"))
    }
}
