# Blurt

**Hold a key, say what you mean, get clean text in whatever app you're in.**
Bring your own API key — or run the whole thing on your own machine.

[![CI](https://github.com/NathanFeeser/blurt/actions/workflows/ci.yml/badge.svg)](https://github.com/NathanFeeser/blurt/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)

## Why this exists

Dictation is a solved research problem and an unsolved product problem. Wispr
Flow and superwhisper are both excellent and both closed. [freeflow][freeflow] is
open but macOS-only and built around one shape of pipeline.

Blurt goes after the three things none of them do together:

1. **Any key, any model.** Transcription and cleanup are separately pluggable —
   Groq, OpenAI, Deepgram, or any OpenAI-compatible endpoint, including your own
   Ollama, LM Studio, or vLLM box. Keys live in the OS keychain.
2. **Cross-platform for real.** One portable Rust core, thin native shells. The
   core is not a macOS library with ambitions; it already builds for iOS and
   Windows in CI, before either shell exists, so the claim cannot rot quietly.
3. **Quality you can measure.** Cleanup — not raw transcription — is what
   separates good dictation from great. [DictBench](eval/) scores the real
   production prompt on real cases, so a prompt change that makes things worse
   shows up as a number instead of a feeling.

[freeflow]: https://github.com/zachlatta/freeflow

## Quickstart

You need macOS 13+, [Rust][rustup], and Xcode 16 or newer.

```bash
git clone https://github.com/NathanFeeser/blurt.git
cd blurt
./scripts/build-macos-app.sh --run      # builds build/Blurt.app and launches it
```

On first launch Blurt asks for **Microphone** and **Accessibility**.
Accessibility is not optional: without it the hotkey installs successfully and
then silently never fires.

Then, from the menu bar icon:

1. **Settings → Providers** — paste a [Groq API key][groq] (free tier is enough
   to start). Or **Settings → General → On this Mac** to download a local model
   and use no API at all.
2. **Settings → General → Microphone** — pin the mic you actually want. Worth
   ten seconds: the system default moves on its own when you connect earbuds,
   and a Bluetooth mic in hands-free mode drops words that no model can recover.
3. **Hold Right Option**, speak, release. The text appears where your cursor is.

Escape while holding cancels. Double-tap to go hands-free, then tap once to
finish. Select text and hold **Right Command** to edit it by voice instead.

[rustup]: https://rustup.rs
[groq]: https://console.groq.com/keys

## What it does

| | |
|---|---|
| **Hold-to-talk and hands-free** | Hold the key, or double-tap to keep recording with your hands free. |
| **Modes** | A mode bundles a transcription model, a cleanup model, a prompt, and formatting rules. Ships with Dictation, Chat, Email, Code, Raw, and a fully offline Private preset. |
| **Per-app switching** | Modes claim apps by bundle id, so Slack gets your chat voice and your editor gets verbatim identifiers, with no thinking about it. |
| **Command mode** | Select text, hold a key, say what to do with it. "Make this shorter." "Turn this into bullets." |
| **On-device** | WhisperKit on the Neural Engine. Nothing leaves the machine, including in a mode that refuses to fall back to a hosted provider even if one is configured. |
| **History** | Everything you dictated, searchable, with the raw transcript kept next to the cleaned-up text. Re-run any entry through a different mode to see what it would have written. Text only — audio is never written to disk. |
| **Undo** | Takes back the last insertion: removes exactly the text it inserted when it can still see it, falls back to ⌘Z, and refuses once you have switched apps. |
| **Custom vocabulary** | Proper nouns and jargon the model would otherwise mangle. |
| **Screen context** | Reads the focused app and nearby text over Accessibility to spell names right and match the surrounding style. Switchable off. |

## How it works

```
  hotkey ──► capture ──► ring buffer ──► transcribe ──► cleanup ──► insert
             (shell)       (core)          (core)        (core)     (shell)
                                             │              │
                                     Groq / OpenAI /   any OpenAI-
                                     Deepgram /        compatible
                                     on-device         model
```

Everything except capture, the hotkey, and text insertion lives in a portable
Rust core with no UI framework and no OS assumptions in it. The shells own only
what is irreducibly platform-specific. That is the whole architectural bet, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) argues it in detail — including the
latency budget the pipeline is held to and where it currently misses.

A **skip gate** decides whether the cleanup model runs at all, because modern
transcription already punctuates and the LLM hop is the largest item in the
latency budget. When it does run, its job is mostly to leave your words alone:
over-editing is the most common failure mode in this category.

## Providers

| id | what it's for |
|---|---|
| `groq` | Default. `whisper-large-v3-turbo` at roughly $0.04/hr of audio. |
| `openai` | Whisper and GPT models. |
| `deepgram` | Streaming-grade transcription. |
| `local` / `whisperkit` | On-device, Neural Engine, no network. |
| `ollama`, `lmstudio`, `vllm` | Your own box. No key needed. |
| `openai-compat` | Anything else that speaks the OpenAI API. |

Point the two stages at different providers if you like — on-device
transcription with a cloud cleanup model is a reasonable combination, and so is
the reverse.

## The CLI

The same pipeline, driven from a terminal. This is the real production code
path, not a reimplementation, which is what makes the eval harness trustworthy.

```bash
cargo run -p blurt-cli -- transcribe recording.wav
cargo run -p blurt-cli -- transcribe recording.wav --mode raw     # skip cleanup
cargo run -p blurt-cli -- providers                               # ids + endpoints
cargo run -p blurt-cli -- check groq                              # verify a key
```

Input must be 16-bit PCM WAV:
`ffmpeg -i in.m4a -ar 16000 -ac 1 -c:a pcm_s16le out.wav`

## Privacy

- **Keys live in the OS keychain.** Never in `UserDefaults`, never in a config
  file, never logged. (The `.env` file is a convenience for the CLI only.)
- **Audio is never written to disk.** It exists in memory for the length of a
  dictation and is dropped.
- **History is local and controllable** — a master switch, a per-mode opt-out
  that ships *off* for the Private preset, and a retention cap. Clearing it
  actually reclaims the pages rather than leaving the text recoverable.
- **Zero telemetry.** There is no analytics code in this repo. If that ever
  changes it will be opt-in, granular, and inspectable in the UI.
- **On-device modes never silently fall back** to a hosted provider. A mode
  chosen for privacy fails loudly instead, and a test enforces it.

Blurt needs Accessibility permission to read context and insert text, which is a
lot of trust to ask for. Being able to read exactly what it does with that
permission is the point of the license.

## Layout

```
crates/blurt-core/    the portable pipeline — no UI, no OS assumptions
crates/blurt-cli/     `blurt`, the terminal driver the eval harness uses
apps/macos/           menu bar app — hotkey, capture, AX context, insertion
eval/                 DictBench: cases, graders, findings
swift/SmokeTest/      proves the Rust <-> Swift boundary works
scripts/              xcframework build, app build, smoke test
docs/                 architecture, research, internal plan
```

## Contributing

Yes, please — see [CONTRIBUTING.md](CONTRIBUTING.md). It covers the build, the
test philosophy, where the seams are, and a worked example of adding a new
transcription provider, which is the most self-contained way in.

## Troubleshooting

**The hotkey does nothing.** Check whether another app binds the same key. An
event tap that *consumes* the press sits upstream of the monitor Blurt listens
on, so the press never arrives — and since the permission and the monitor are
both fine, nothing reports a problem. `~/Library/Logs/Blurt.log` records every
press that does arrive, so an empty log during a press is the signature.
Settings → Gestures moves Blurt to a different key.

**Quality suddenly got worse.** Check the microphone named in the recording
overlay. A Bluetooth headset connecting quietly takes over the system default
input, and its hands-free mode is narrowband and noise-gated — transcripts come
back with words missing. Pin your real mic in Settings → General.

**Permission prompts return after every rebuild.** macOS ties grants to the code
signature, and ad-hoc rebuilds look like a new app each time. Set
`BLURT_SIGN_IDENTITY` to a stable Developer ID to keep them.

## Roadmap

[ROADMAP.md](ROADMAP.md) — what is shipped, what is next, and what this project
deliberately will not do.

## License

Apache-2.0. See [LICENSE](LICENSE).
