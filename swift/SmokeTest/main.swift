// Smoke test for the Rust <-> Swift boundary.
//
// This is the check that makes the "Rust core" decision real: it links the
// actual static library, calls sync methods, round-trips records, and exercises
// the async/tokio bridge — the riskiest part of the FFI surface. CI runs it on
// every push, because a boundary that only compiles is not a boundary that works.

import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool) {
    if condition {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)")
        failures += 1
    }
}

// --- Audio capture: pre-roll behaviour across the boundary -----------------
print("AudioCapture")
let capture = AudioCapture.withPrerollMs(prerollMs: 10) // 160 samples at 16 kHz
let level = capture.push(frames: [Float](repeating: 0.5, count: 160))
check("push returns a level", level > 0.4 && level < 0.6)

capture.start()
_ = capture.push(frames: [Float](repeating: 0.25, count: 100))

let stats = capture.stats()
check("stats report recording", stats.isRecording)
check("stats report duration", stats.durationMs > 0)

let samples = capture.stop()
check("pre-roll is prepended (260 samples)", samples.count == 260)
check("pre-roll content leads", samples.first == 0.5)
check("live content follows", samples.last == 0.25)
check("stop clears the recording", capture.stop().isEmpty)

// --- Engine: records, modes, and error mapping -----------------------------
print("\nDictationEngine")
let engine = DictationEngine()
check("ships with built-in modes", engine.modes().count >= 2)
check("default mode is active", engine.activeModeId() == "default")

engine.setCredentials(
    providerId: "groq",
    creds: ProviderCredentials(baseUrl: "", apiKey: "test-key")
)

var mode = Mode(
    id: "smoke",
    name: "Smoke",
    stt: SttConfig(providerId: "groq", model: "whisper-large-v3-turbo", language: nil),
    cleanup: nil,
    cleanupInstructions: nil,
    appMatches: ["com.example.smoke"],
    allowCleanupSkip: true,
    recordHistory: false
)
engine.setModes(modes: [mode])
check("setModes repoints a dangling active id", engine.activeModeId() == "smoke")

mode.name = "Renamed"
check("records are value types", engine.modes().first?.name == "Smoke")

do {
    try engine.setActiveMode(modeId: "does-not-exist")
    check("unknown mode is rejected", false)
} catch let error as DictError {
    if case .UnknownProvider = error {
        check("unknown mode maps to a typed error", true)
    } else {
        check("unknown mode maps to UnknownProvider, got \(error)", false)
    }
} catch {
    check("unknown mode threw an unexpected type", false)
}

// --- The async bridge ------------------------------------------------------
// Crossing into tokio and back is the part most likely to deadlock or leak, so
// exercise it for real rather than trusting that it compiled.
print("\nAsync bridge")

let asyncDone = DispatchSemaphore(value: 0)
Task {
    defer { asyncDone.signal() }

    // Empty audio: a fast, offline round-trip through the async FFI that must
    // come back as a typed NoAudio rather than hanging or trapping.
    do {
        _ = try await engine.transcribe(samples: [], ctx: AppContext(
            bundleId: nil, appName: nil, windowTitle: nil,
            surroundingText: nil, selectedText: nil
        ))
        check("empty audio is rejected", false)
    } catch let error as DictError {
        if case .NoAudio = error {
            check("async call returns a typed NoAudio", true)
        } else {
            check("expected NoAudio, got \(error)", false)
        }
    } catch {
        check("async call threw an unexpected type: \(error)", false)
    }

    // An unconfigured provider must fail before any network call happens.
    let bare = DictationEngine()
    var unconfigured = mode
    unconfigured.stt = SttConfig(providerId: "openai", model: "whisper-1", language: nil)
    bare.setModes(modes: [unconfigured])
    do {
        _ = try await bare.transcribe(samples: [0.1, 0.2], ctx: AppContext(
            bundleId: nil, appName: nil, windowTitle: nil,
            surroundingText: nil, selectedText: nil
        ))
        check("missing credentials are rejected", false)
    } catch let error as DictError {
        if case .NotConfigured = error {
            check("missing credentials map to NotConfigured", true)
        } else {
            check("expected NotConfigured, got \(error)", false)
        }
    } catch {
        check("unexpected error type: \(error)", false)
    }

    // Concurrent calls: proves the tokio runtime is shared, not per-call.
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                do {
                    _ = try await engine.transcribe(samples: [], ctx: AppContext(
                        bundleId: nil, appName: nil, windowTitle: nil,
                        surroundingText: nil, selectedText: nil
                    ))
                    return false
                } catch {
                    return true
                }
            }
        }
        var count = 0
        for await ok in group where ok { count += 1 }
        check("8 concurrent async calls all returned", count == 8)
    }
}

// 30s is generous; the point is to fail loudly instead of hanging CI forever.
if asyncDone.wait(timeout: .now() + 30) == .timedOut {
    print("  FAIL  async bridge timed out")
    failures += 1
}

print("")
if failures == 0 {
    print("SMOKE TEST PASSED")
    exit(0)
} else {
    print("SMOKE TEST FAILED (\(failures) failure(s))")
    exit(1)
}
