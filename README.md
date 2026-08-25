# Blurt

Hold a key, say what you mean, and get clean text in whatever app you're in.
Bring your own API key, or run the whole thing on your own machine.

[![CI](https://github.com/NathanFeeser/blurt/actions/workflows/ci.yml/badge.svg)](https://github.com/NathanFeeser/blurt/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)

## Why this exists

Dictation is a solved research problem and an unsolved product problem. Wispr
Flow and superwhisper are both good, and both closed. The open options I looked
at were macOS-only and built around one shape of pipeline.

So Blurt is built around three commitments.

Transcription and cleanup are separately pluggable. Point them at Groq, OpenAI,
Deepgram, or any OpenAI-compatible endpoint, including your own Ollama, LM
Studio, or vLLM box. Keys live in the OS keychain and nowhere else.

The core is portable, and not in the aspirational sense. It's a Rust library
with no UI framework in it, and it compiles and tests on iOS and Windows in CI
today, before either shell exists. That way the claim can't rot quietly while
only the Mac gets attention.

Quality is measurable. What separates good dictation from great is the cleanup
stage, not the transcription. [DictBench](eval/) runs the real production prompt
against real cases, so a prompt change that makes things worse shows up as a
number instead of a feeling.

## Quickstart

You need macOS 13 or newer, [Rust](https://rustup.rs), and Xcode 16+.

```bash
git clone https://github.com/NathanFeeser/blurt.git
cd blurt
./scripts/build-macos-app.sh --run      # builds build/Blurt.app and launches it
```

First launch asks for Microphone and Accessibility. Accessibility is not
optional. Without it the hotkey installs successfully and then silently never
fires, which is the most confusing failure this app has.

Then, from the menu bar icon:

1. **Providers.** Paste a [Groq API key](https://console.groq.com/keys); the free
   tier is plenty to start. Or open General, switch to "On this Mac", and
   download a local model instead. No key, no network.
2. **Microphone.** Pin the mic you actually want. This is worth ten seconds of
   your time: the system default moves on its own when you connect earbuds, and
   a Bluetooth mic in hands-free mode drops words that no model can recover.
3. **Hold Right Option**, speak, release. The text lands wherever your cursor is.

Escape while holding cancels. Double-tap to go hands-free, then tap once to
finish. To edit text you already have, select it and hold Right Command instead.

## What it does

| | |
|---|---|
| **Hold-to-talk and hands-free** | Hold the key, or double-tap to keep recording with your hands free. |
| **Modes** | A mode bundles a transcription model, a cleanup model, a prompt, and formatting rules. Ships with Dictation, Chat, Email, Code, Raw, and a fully offline Private preset. |
| **Per-app switching** | Modes claim apps by bundle id, so Slack gets your chat voice and your editor gets verbatim identifiers, without you thinking about it. |
| **Command mode** | Select text, hold a key, say what to do with it. "Make this shorter." "Turn this into bullets." |
| **On-device** | WhisperKit on the Neural Engine. Nothing leaves the machine, and a mode set to on-device refuses to fall back to a hosted provider even when one is configured. |
| **History** | Everything you've dictated, searchable, with the raw transcript kept alongside the cleaned-up text. Re-run any entry through a different mode to see what it would have written. Text only. Audio is never written to disk. |
| **Undo** | Takes back the last insertion. It removes exactly the text it inserted when it can still see it, falls back to ⌘Z when it can't, and refuses outright once you've switched apps. |
| **Custom vocabulary** | Proper nouns and jargon the model would otherwise mangle. |
| **Screen context** | Reads the focused app and nearby text over Accessibility, to spell names right and match the surrounding style. Switchable off. |

## How it works

```
  hotkey ──► capture ──► ring buffer ──► transcribe ──► cleanup ──► insert
             (shell)       (core)          (core)        (core)     (shell)
                                             │              │
                                     Groq / OpenAI /   any OpenAI-
                                     Deepgram /        compatible
                                     on-device         model
```

Capture, the hotkey, and text insertion are the only parts that live in the
macOS app. Everything else is in a portable Rust core with no UI framework and
no OS assumptions in it. That's the whole architectural bet, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) argues it properly, including the
latency budget the pipeline is held to and where it currently misses.

One design note worth knowing about: a skip gate decides whether the cleanup
model runs at all. Modern transcription already punctuates, and the LLM hop is
the largest single item in the latency budget. When cleanup does run, most of
its job is leaving your words alone. Over-editing is the most common failure
mode in this category, and it's the one users notice.

## Providers

| id | what it's for |
|---|---|
| `groq` | The default. `whisper-large-v3-turbo`, around $0.04 per hour of audio. |
| `openai` | Whisper and GPT models. |
| `deepgram` | Streaming-grade transcription. |
| `local` / `whisperkit` | On-device, Neural Engine, no network. |
| `ollama`, `lmstudio`, `vllm` | Your own box. No key needed. |
| `openai-compat` | Anything else that speaks the OpenAI API. |

The two stages are independent, so mix them if you like. On-device
transcription with a cloud cleanup model is a reasonable setup, and so is the
reverse.

## The CLI

The same pipeline from a terminal. This is the real production code path rather
than a reimplementation of it, which is what makes the eval harness worth
trusting.

```bash
cargo run -p blurt-cli -- transcribe recording.wav
cargo run -p blurt-cli -- transcribe recording.wav --mode raw     # skip cleanup
cargo run -p blurt-cli -- providers                               # ids + endpoints
cargo run -p blurt-cli -- check groq                              # verify a key
```

Input must be 16-bit PCM WAV:
`ffmpeg -i in.m4a -ar 16000 -ac 1 -c:a pcm_s16le out.wav`

## Privacy

Blurt needs Accessibility permission to read context and insert text. That's a
lot of trust to ask for, so here's exactly what it does with it.

Keys live in the OS keychain. Never in `UserDefaults`, never in a config file,
never in a log. The `.env` file is a convenience for the CLI only.

Audio is never written to disk. It exists in memory for the length of one
dictation and is then dropped.

History is local, and you control it three ways: a master switch, a per-mode
opt-out that ships off for the Private preset, and a retention cap. Clearing it
reclaims the pages rather than leaving the text sitting there recoverable.

There is no telemetry. No analytics code exists in this repo. If that ever
changes it will be opt-in, granular, and inspectable in the UI.

On-device modes never silently fall back to a hosted provider. A mode chosen for
privacy fails loudly instead, and there's a test that enforces it.

## Layout

```
crates/blurt-core/    the portable pipeline. No UI, no OS assumptions.
crates/blurt-cli/     `blurt`, the terminal driver the eval harness uses
apps/macos/           menu bar app: hotkey, capture, AX context, insertion
eval/                 DictBench: cases, graders, findings
swift/SmokeTest/      proves the Rust/Swift boundary works
scripts/              xcframework build, app build, smoke test
docs/                 architecture, research, internal plan
```

## Contributing

Yes please. [CONTRIBUTING.md](CONTRIBUTING.md) covers the build, the test
philosophy, where the seams are, and a worked example of adding a transcription
provider, which is the most self-contained way into the codebase.

## Troubleshooting

**The hotkey does nothing.** Check whether another app has claimed the same key.
An event tap that consumes the press sits upstream of the monitor Blurt listens
on, so the press never arrives, and since the permission and the monitor are
both fine nothing reports a problem. `~/Library/Logs/Blurt.log` records every
press that does arrive, so an empty log while you're pressing the key is the
signature. Settings → Gestures moves Blurt to a different key.

**Quality suddenly got worse.** Look at the microphone named in the recording
overlay. A Bluetooth headset connecting will quietly take over the system
default input, and its hands-free mode is narrowband and noise-gated, so
transcripts come back with words missing. Pin your real mic in Settings →
General.

**Permission prompts come back after every rebuild.** macOS ties grants to the
code signature, and ad-hoc rebuilds look like a new app each time. Set
`BLURT_SIGN_IDENTITY` to a stable Developer ID to keep them.

## Roadmap

[ROADMAP.md](ROADMAP.md) covers what's shipped, what's next, and what this
project deliberately won't do.

## License

Apache-2.0. See [LICENSE](LICENSE).
