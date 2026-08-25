# Decision log

Dated entries recording what was decided and what evidence decided it. Most of
these were settled by measuring something rather than by argument, and the
measurement is the part worth keeping.

Before reopening one of these, check what is written here. If the reasoning is
wrong that is worth knowing, and if the evidence has changed that is worth
knowing too. Either way the argument starts from what was already measured.

| Date | Decision | Why |
|---|---|---|
| 2026-08-24 | Rust core with UniFFI, not Swift-first | Windows is a real roadmap item, so the pipeline gets written once. Validated the same day: the xcframework built for every Apple slice and a Swift binary called through the async boundary. |
| 2026-08-24 | rustls with the `ring` provider, not aws-lc-rs | aws-lc-sys mis-links on iOS without explicit deployment targets and needs NASM on Windows. `ring` ships pregenerated assembly and cross-compiles cleanly. |
| 2026-08-24 | Batch transcription first, streaming as a per-mode setting later | Streaming tiers cost several times more, and the latency win only matters once the rest of the path is tight. |
| 2026-08-24 | Cleanup skip gate on by default, per-mode override | The LLM hop is the largest item in the latency budget and modern transcription already punctuates. Conservative by design: when unsure, run cleanup. |
| 2026-08-24 | Default cleanup model `openai/gpt-oss-120b`, not `gpt-oss-20b` | Measured live. The 20b model returns dictation verbatim and applies no self-corrections; 120b handles them at comparable latency. `llama-3.3-70b-versatile` is decommissioned on Groq. |
| 2026-08-24 | Strip `<think>` blocks in the pipeline, not the prompt | Reasoning models are common defaults now and leak chain-of-thought inline. An unterminated block means the answer was truncated, so it degrades to the raw transcript rather than shipping reasoning into the user's document. |
| 2026-08-24 | The mic opens on the hotkey, not continuously | Measured engine start at roughly 90 ms rather than the assumed 100 to 300, so pre-roll was buying little. A menu bar app whose mic indicator is permanently lit looks like it is always listening. |
| 2026-08-24 | Keep both insertion paths | Verified in real use. Accessibility insertion fires in native text views such as Notes, TextEdit, and Spotlight; paste covers browsers, Electron, and terminals. Neither alone is sufficient. |
| 2026-08-24 | The cleanup token budget must cover reasoning tokens | Root cause of dictations truncating mid-sentence. gpt-oss-120b spends a few hundred reasoning tokens before writing anything, and those count against `max_tokens`. |
| 2026-08-24 | `finish_reason == "length"` is a cleanup failure, not a result | A truncated completion returns the first half of a sentence and looks like success. Failing makes the pipeline fall back to the full raw transcript. |
| 2026-08-24 | `reasoning_effort: "low"` for cleanup | Confirmed by DictBench across three effort levels: low matched medium on correctness with a lower median latency, and higher effort edited more aggressively, which is the opposite of what this stage wants. See `eval/FINDINGS.md`. |
| 2026-08-24 | Pre-roll is discarded when audio is not continuous | Closing the microphone between dictations left the ring buffer holding the previous dictation's tail, which got prepended to the next sentence. The core now drops stale pre-roll and exposes `reset()` for shells that close the mic. Any shell that opens the mic per dictation would hit this identically. |
| 2026-08-24 | On-device inference stays in the shell, behind a foreign trait | The core defines `LocalTranscriber` and calls it. WhisperKit and CoreML live in Swift; whisper.cpp or ONNX will live in the Windows shell. The core orchestrates rather than hosting an inference engine per platform. |
| 2026-08-24 | On-device modes never fall back to a hosted provider | A mode chosen for privacy must fail loudly rather than quietly send audio to a server. Enforced by a test. |
| 2026-08-24 | `SttRequest` carries samples, not an encoded WAV | Each provider owns its wire format. Encoding a WAV for WhisperKit to immediately decode was pure waste, and it removes a hop from the on-device path. |
| 2026-08-24 | `local` means on-device, never a localhost server | The id previously mapped to the OpenAI-compatible adapter, so it meant two things at once. Servers on localhost are reached by their own ids (`ollama`, `lmstudio`, `vllm`), which separately were not resolving at all. |
| 2026-08-24 | Apache-2.0 for the clients | Permissive licensing drives adoption and the patent grant is worth having. |
| 2026-08-25 | History is SQLite in the core, not per-shell storage | One schema and one set of tests, and iOS and Windows inherit it by existing. It is also the substrate the correction flywheel needs later, so putting it in a shell would mean building it twice. |
| 2026-08-25 | History keeps text, never audio | Keeps the privacy promise to one sentence, which matters when asking for Accessibility permission. The cost is that re-run means re-running cleanup rather than re-transcribing, and trying a different prompt on what you actually said is the more useful half anyway. |
| 2026-08-25 | Undo refuses rather than guesses once the frontmost app has changed | A ⌘Z aimed at the wrong window destroys work the user did themselves. Undo removes the exact inserted text when Accessibility can still see it, falls back to ⌘Z in the same app, and declines otherwise. |
| 2026-08-25 | The input device is pinnable in the app, not inherited from the system default | Connecting Bluetooth earbuds moved the system default to their hands-free mic and dictation quality collapsed, with transcripts missing words mid-sentence, while nothing in the app said a word about it. An hour went into suspecting the model, which was the one part that was fine. |
| 2026-08-25 | Named Blurt | "OpenDict" reads as an open dictionary to anyone who has typed Python, so it described a project we are not building. |
| 2026-08-25 | Bundle identifier `com.nerflabs.blurt` | Reverse-DNS should name a domain that is actually owned. Changing it costs one permission re-grant now and none later. |
