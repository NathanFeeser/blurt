import Foundation
import OpenDictCore
import WhisperKit

/// On-device transcription via WhisperKit, running Whisper on the Neural Engine.
///
/// This is the shell's side of the core's `LocalTranscriber` boundary. The core
/// orchestrates and never learns whether audio left the machine; this class is
/// the only place CoreML is mentioned.
///
/// Loading is deliberately lazy and non-blocking. A model is hundreds of
/// megabytes and takes seconds to load, so the app must stay usable while that
/// happens: `isReady()` reports false and the engine surfaces a clear error
/// rather than a mode hanging on first use.
final class WhisperKitTranscriber: LocalTranscriber, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready(String)
        case failed(String)
    }

    private let lock = NSLock()
    private var whisper: WhisperKit?
    private var _state: State = .idle
    private var variant: String

    var onStateChange: ((State) -> Void)?

    var state: State {
        lock.withLock { _state }
    }

    init(variant: String) {
        self.variant = variant
    }

    // MARK: - LocalTranscriber (called from Rust)

    func modelName() -> String {
        lock.withLock { variant }
    }

    func isReady() -> Bool {
        lock.withLock {
            if case .ready = _state { return whisper != nil }
            return false
        }
    }

    func transcribe(samples: [Float], language: String?) async throws -> String {
        let model = lock.withLock { whisper }

        guard let model else {
            throw DictError.NotConfigured(message: "the on-device model is not loaded")
        }

        // Temperature 0 and no fallbacks: dictation wants the single most likely
        // transcript, and the fallback retries cost real time on device.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 0,
            // Whisper hallucinates confidently on silence; VAD chunking keeps it
            // from inventing text for the pauses in a long hands-free dictation.
            chunkingStrategy: .vad
        )

        do {
            let results = try await model.transcribe(audioArray: samples, decodeOptions: options)
            return results.map(\.text).joined(separator: " ")
        } catch {
            throw DictError.BadResponse(message: "on-device transcription failed: \(error)")
        }
    }

    // MARK: - Model lifecycle

    /// Download if needed and load. Safe to call repeatedly; concurrent calls
    /// after the first are ignored rather than starting a second download.
    func prepare(variant: String? = nil) {
        let target: String? = lock.withLock {
            if let variant { self.variant = variant }
            let target = self.variant
            switch _state {
            case .downloading, .loading:
                return nil
            case .ready(let loaded) where loaded == target:
                return nil
            default:
                set(.loading)
                return target
            }
        }
        guard let target else { return }

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let config = WhisperKitConfig(
                    model: target,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: true
                )
                let kit = try await WhisperKit(config)
                self.lock.withLock {
                    self.whisper = kit
                    self.set(.ready(target))
                }
                Diag.log("on-device model ready: \(target)")
            } catch {
                self.lock.withLock {
                    self.whisper = nil
                    self.set(.failed("\(error)"))
                }
                Diag.log("on-device model failed to load: \(error)")
            }
        }
    }

    func unload() {
        lock.withLock {
            whisper = nil
            set(.idle)
        }
    }

    /// Caller must hold the lock.
    private func set(_ new: State) {
        _state = new
        let callback = onStateChange
        // Off the lock: observers update UI and must not re-enter.
        DispatchQueue.main.async { callback?(new) }
    }

    /// Models worth offering. The full list from Hugging Face is long and mostly
    /// noise for dictation; these are the accuracy/size tradeoffs that matter.
    static let suggestedVariants = [
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-small.en",
        "openai_whisper-base.en",
        "openai_whisper-tiny.en",
    ]

    static func displayName(_ variant: String) -> String {
        switch variant {
        case "openai_whisper-large-v3-v20240930_turbo": return "Large v3 Turbo — best accuracy (~950 MB)"
        case "openai_whisper-small.en": return "Small (English) — balanced (~250 MB)"
        case "openai_whisper-base.en": return "Base (English) — fast (~150 MB)"
        case "openai_whisper-tiny.en": return "Tiny (English) — fastest (~80 MB)"
        default: return variant
        }
    }
}
