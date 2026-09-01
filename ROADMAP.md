# Roadmap

Blurt is built by one person, so this is sequenced rather than parallel, and the
gates between phases are real. The reasoning behind individual technical
decisions is recorded in [docs/DECISIONS.md](docs/DECISIONS.md).

Dates are deliberately absent. The ordering is the commitment.

## Shipped

The macOS app is usable every day, today, by anyone willing to build it.

- Portable Rust core with a UniFFI boundary, building for macOS, iOS, and
  Windows in CI
- `blurt` CLI running the identical pipeline, which is what makes evaluation honest
- Hold-to-talk, hands-free double-tap, escape-to-cancel
- Modes with per-app auto-switching
- Command mode — select text, speak an instruction
- Accessibility insertion with a clipboard fallback, because neither alone
  covers every app
- On-device transcription via WhisperKit, and a Private preset that never falls
  back to the network
- Screen-context and custom vocabulary injection
- Local history with search, re-run, and undo
- Microphone pinning, so a Bluetooth headset cannot quietly take over dictation
- Keychain key storage, a settings UI, and a test suite across both languages
- Signed, notarized, universal releases that install from a `.dmg` and update
  themselves through Sparkle
- A first-run setup flow that refuses to advance until each thing it asked for
  is actually true, and ends with a real dictation

## Now — quality you can prove

The macOS app is done for now: it installs, updates itself, and explains
itself. What it needs next is evidence, not features.

[DictBench](eval/) exists and already settled one real question (see
`eval/FINDINGS.md`), but it is text-only and small. In order:

- [ ] **CI gate on prompt and model changes**, so a prompt edit that regresses
      "leave clean text alone" fails the build. Cheapest, and the most
      protection per hour of anything here.
- [ ] **An LLM grader for voice and style.** Deterministic assertions cannot tell
      you that a rewrite is technically correct and sounds nothing like you.
- [ ] **Latency instrumentation** enforcing the budget in
      `docs/ARCHITECTURE.md` rather than trusting that it holds. Every dictation
      already logs its timings; this is aggregation and an assertion.
- [ ] **Audio-level cases.** Every case today feeds clean text to the cleanup
      stage, so an entire class of failure — degraded microphone, clipped audio,
      background noise — is invisible to the suite. A real quality regression
      caused by a Bluetooth microphone went undetected by every passing case.
- [ ] **A published benchmark table** comparing provider and prompt combinations.
      Nobody has a good public benchmark for dictation as opposed to
      transcription, and building one in the open is worth more than any feature
      on this list.

Underneath all of it: cases come from real dictations that went wrong. History
keeps the raw transcript beside the final text, which is what makes a bad
dictation a cheap test case.

## macOS — nice to have

Each of these improves quality or breadth, and each waits for evidence from real
use that it matters. None is a prerequisite for anything else here, and the app
is deliberately not growing until something is.

- [ ] **Streaming transcription** as a per-mode setting. Batch is substantially
      cheaper and is the right default; streaming is what removes the upload and
      most of the transcription time from the critical path, which is the
      difference between fast and instant.
- [ ] **Deeper screen-context scraping.** What exists is shallow. This is where
      most of the perceived intelligence lives.
- [ ] **More providers** — ElevenLabs and Qwen adapters.

## Later — the other platforms

- [ ] **Windows.** First, because the macOS value proposition translates: a
      native shell over the same core, clipboard injection with save and
      restore, a low-level keyboard hook, UI Automation for context. The core
      already compiles and tests on Windows in CI so that this stays a UI
      project rather than a rewrite.
- [ ] **iOS.** The hard one, and deferred on purpose: iOS has no system-wide
      text insertion, and ships excellent free dictation one tap from every
      keyboard, so the wedge is narrower. The container app owns the microphone
      and a keyboard extension triggers it over an App Group; the mic
      restriction is kernel-enforced and not negotiable. Before any app, a
      throwaway spike on whether that round trip feels acceptable. If it does
      not, iOS ships as an app-first experience instead of a keyboard.

## Someday — a model of our own

Gated on evidence, not enthusiasm: enough opted-in correction data, plus
DictBench showing that the cleanup stage is where quality is actually lost.

- A small cleanup model fine-tuned on `(raw transcript + context) → final text`,
  which would collapse the largest latency and cost line in the pipeline
- Eventually, an audio-native model that skips the two-hop pipeline entirely
- Custom-vocabulary adaptation beyond prompt biasing

## Not planned

Saying no clearly is what keeps the rest shippable. Blurt is not going to do:

- **Meeting transcription or diarization.** A different product with a different
  UI, different latency needs, and different privacy problems.
- **Real-time translation**, text-to-speech, or a web app.
- **Linux or Android.** Not hostility — sequencing. Two platforms are already
  ahead of them in the queue.
- **A crippled free tier.** The BYOK app is the product and stays complete. A
  managed tier for people who would rather not handle API keys may fund the
  work later; it will be the same app with a login instead of a key field.

## How to help

The most useful contributions right now, in rough order:

1. **Use it and report what is wrong.** Especially quality regressions — the
   local history makes a good bug report cheap, since it stores the raw
   transcript next to what was inserted.
2. **DictBench cases.** Dictation that came out wrong is a test case, and this
   is the part of the project that compounds.
3. **Providers.** Self-contained, well-bounded, and covered by
   [CONTRIBUTING.md](CONTRIBUTING.md).
4. **The Windows shell.** The core is ready and waiting for one.
