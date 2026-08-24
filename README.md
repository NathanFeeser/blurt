# OpenDict

Open-source, bring-your-own-key AI dictation. Hold a hotkey, speak, and get clean,
formatted text in whatever app you're in — on macOS, Windows, and iOS.

**Status:** Phase 0. The portable core, the CLI, the Rust/Swift boundary, and a
dogfoodable macOS menu bar app all build and run. See [`docs/PLAN.md`](docs/PLAN.md).

## Why

Wispr Flow and superwhisper are excellent and closed. [freeflow](https://github.com/zachlatta/freeflow)
is open but macOS-only, single-target, and hardwired around one shape of pipeline.

OpenDict aims at three things none of them do together:

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
cargo run -p opendict-cli -- transcribe recording.wav

# Point either stage anywhere, including your own box.
cargo run -p opendict-cli -- transcribe recording.wav \
  --stt-provider vllm --stt-model openai/whisper-large-v3 \
  --llm-provider ollama --llm-model qwen3:4b

# Skip the LLM stage entirely for the lowest-latency path.
cargo run -p opendict-cli -- transcribe recording.wav --mode raw

# Simulate what the desktop shell will pass in.
cargo run -p opendict-cli -- transcribe recording.wav \
  --app com.tinyspeck.slackmacgap \
  --context "Shipping the Parakeet migration this week." \
  --vocab "Parakeet,WhisperKit,n8" --json

cargo run -p opendict-cli -- providers      # endpoints + which keys were found
cargo run -p opendict-cli -- check groq     # verify a key actually works
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
./scripts/build-macos-app.sh --run         # -> build/OpenDict.app, then launches it
```

First run asks for **Microphone** and **Accessibility**. Accessibility is
non-negotiable: without it the hotkey installs successfully and then silently
never fires. Then use the menu bar icon to set your API key (stored in the login
keychain), and **hold Right Option** to dictate. Escape while holding cancels.

The microphone runs continuously so the pre-roll buffer can catch words spoken a
beat before the key registers — which means the orange mic indicator stays on
while the app runs. "Pause Microphone" in the menu turns it off at the cost of
pre-roll.

Rebuilds are ad-hoc signed, and macOS ties permission grants to the signature, so
each rebuild is treated as a new app. Set `OPENDICT_SIGN_IDENTITY` to a stable
Developer ID to keep your grants across builds.

## Building the Apple framework

```bash
./scripts/build-xcframework.sh --release   # -> build/OpenDictCore.xcframework
./scripts/swift-smoke.sh release           # exercises the FFI boundary for real
```

## Layout

```
crates/opendict-core/   the portable pipeline — no UI, no OS assumptions
crates/opendict-cli/    `opendict`, the terminal driver the eval harness uses
apps/macos/             menu bar app — hotkey, capture, AX context, insertion
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
