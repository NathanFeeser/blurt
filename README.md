# Blurt

Open-source, bring-your-own-key AI dictation. Hold a hotkey, speak, and get clean,
formatted text in whatever app you're in — on macOS, Windows, and iOS.

**Status:** Phase 0. The portable core, the CLI, the Rust/Swift boundary, and a
dogfoodable macOS menu bar app all build and run. See [`docs/PLAN.md`](docs/PLAN.md).

## Why

Wispr Flow and superwhisper are excellent and closed. [freeflow](https://github.com/zachlatta/freeflow)
is open but macOS-only, single-target, and hardwired around one shape of pipeline.

Blurt aims at three things none of them do together:

1. **Any key, any model.** Transcription and cleanup are both pluggable — Groq, OpenAI,
   Deepgram, ElevenLabs, Qwen, or any OpenAI-compatible endpoint including your own
   Ollama / LM Studio / vLLM box. Keys live in the OS keychain and never leave the device.
2. **Cross-platform from day one.** One portable core, thin native shells. macOS + iOS first,
   Windows next.
3. **Measurable dictation quality.** An open eval suite for the thing that actually matters —
   not raw WER, but "did the final text say what I meant, formatted how I'd have typed it."

An optional paid tier uses our keys for people who don't want to manage their own.
The BYOK app stays free and complete — no crippled free tier.

## Quickstart

```bash
cp .env.example .env      # then put your key in it
$EDITOR .env

# Run the pipeline from the terminal — this is the production code path.
cargo run -p blurt-cli -- transcribe recording.wav

# Point either stage anywhere, including your own box.
cargo run -p blurt-cli -- transcribe recording.wav \
  --stt-provider vllm --stt-model openai/whisper-large-v3 \
  --llm-provider ollama --llm-model qwen3:4b

# Skip the LLM stage entirely for the lowest-latency path.
cargo run -p blurt-cli -- transcribe recording.wav --mode raw

# Simulate what the desktop shell will pass in.
cargo run -p blurt-cli -- transcribe recording.wav \
  --app com.tinyspeck.slackmacgap \
  --context "Shipping the Parakeet migration this week." \
  --vocab "Parakeet,WhisperKit,n8" --json

cargo run -p blurt-cli -- providers      # endpoints + which keys were found
cargo run -p blurt-cli -- check groq     # verify a key actually works
```

`.env` is read from the repo root (searching upward, so it works from any
subdirectory) and is gitignored. Exported shell variables work too.

**This is a development convenience for the CLI only.** The shipped apps read keys
from the OS keychain and never from a file on disk — see the privacy model in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

Input must be 16-bit PCM WAV. Convert anything else with
`ffmpeg -i in.m4a -ar 16000 -ac 1 -c:a pcm_s16le out.wav`.

## The macOS app

```bash
./scripts/build-macos-app.sh --run         # -> build/Blurt.app, then launches it
```

First run asks for **Microphone** and **Accessibility**. Accessibility is
non-negotiable: without it the hotkey installs successfully and then silently
never fires. Then use the menu bar icon to set your API key (stored in the login
keychain), and **hold Right Option** to dictate. Escape while holding cancels.

The microphone opens when you press the hotkey and closes when you release it,
so the orange mic indicator is lit only while you are actually dictating.
Measured engine start is ~90 ms, which is why a permanently-open mic was not
worth the "is this thing always listening?" question it invites.

Everything you dictate is kept in a local history — text only, never audio —
searchable from **Settings → History**, with the last few in the menu bar. Any
entry can be re-run through a different mode's cleanup to see what it would have
written. **Undo Last Insertion** takes back what was just typed into another
app: it removes exactly the inserted text when it can still see it, falls back
to ⌘Z, and refuses outright once you have switched apps. History is off for the
Private preset and can be switched off per mode or entirely.

**Pick your microphone in Settings → General.** Blurt follows the system
default input unless you pin one, and the system default is a shared setting
other things move — connecting Bluetooth earbuds hands dictation to their
hands-free mic, which is narrowband and noise-gated, and transcripts come back
with words missing. Pinning the built-in mic keeps dictation there while you
listen through anything you like. The mic in use is shown while recording, in
the menu, and in the log, and a Bluetooth one is flagged.

If the hotkey does nothing at all, check whether another app binds the same key.
A global event tap that *consumes* the key press sits upstream of the monitor
Blurt listens on, so the press never arrives — and because the permission and
the monitor are both fine, nothing anywhere reports a problem. `~/Library/Logs/
Blurt.log` records every arriving press, so an empty log during a press is
the signature of this. Settings → Gestures moves Blurt to a different key.

Rebuilds are ad-hoc signed, and macOS ties permission grants to the signature, so
each rebuild is treated as a new app. Set `BLURT_SIGN_IDENTITY` to a stable
Developer ID to keep your grants across builds.

## Building the Apple framework

```bash
./scripts/build-xcframework.sh --release   # -> build/BlurtCore.xcframework
./scripts/swift-smoke.sh release           # exercises the FFI boundary for real
```

## Layout

```
crates/blurt-core/   the portable pipeline — no UI, no OS assumptions
crates/blurt-cli/    `blurt`, the terminal driver the eval harness uses
apps/macos/             menu bar app — hotkey, capture, AX context, insertion, history UI
swift/SmokeTest/        proves the Rust <-> Swift boundary works
scripts/                xcframework build, smoke test
docs/                   plan, architecture, research
```

## Docs

| | |
|---|---|
| [`docs/PLAN.md`](docs/PLAN.md) | Product scope, phased roadmap, business model, open questions |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | System design, latency budget, platform constraints |
| [`docs/RESEARCH.md`](docs/RESEARCH.md) | Competitive teardown, model/provider landscape, cost math |

## License

Not yet chosen — see the licensing section in `docs/PLAN.md`. Leaning Apache-2.0 for the
clients, with model weights and the managed backend held separately.
