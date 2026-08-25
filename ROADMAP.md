# Roadmap

Blurt is built by one person, so this is sequenced rather than parallel, and the
gates between phases are real. The internal planning document with the reasoning
behind each decision lives in [docs/PLAN.md](docs/PLAN.md); this is the public
version of where things stand.

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
- Keychain key storage, a settings UI, and 135 tests

## Now — finishing the macOS app

The goal is a signed, notarized v0.1 that people can download and run without a
toolchain.

- [ ] **Developer ID signing, notarization, and Sparkle updates.** The actual
      gate on a public download.
- [ ] **Streaming transcription** as a per-mode setting. Batch is 5–10x cheaper
      and is the right default; streaming is what removes the upload and most of
      the transcription time from the critical path. The latency budget is
      currently missed for exactly this reason — p50 ≈ 750 ms against a 600 ms
      target, measured, documented in `docs/ARCHITECTURE.md`.
- [ ] **Deeper screen-context scraping.** What exists is shallow. This is where
      most of the perceived intelligence lives.
- [ ] **More providers** — ElevenLabs and Qwen adapters.
- [ ] **Onboarding** that explains the Accessibility prompt honestly instead of
      hoping people click through it.

## Next — quality you can prove

[DictBench](eval/) exists and already settled one real question (see
`eval/FINDINGS.md`), but it is text-only and small.

- [ ] **An LLM grader for voice and style.** Deterministic assertions cannot tell
      you that a rewrite is technically correct and sounds nothing like you.
- [ ] **Audio-level cases.** Every case today feeds clean text to the cleanup
      stage, so an entire class of failure — degraded microphone, clipped audio,
      background noise — is invisible to the suite. A real quality regression
      caused by a Bluetooth mic went undetected by 21 passing cases.
- [ ] **CI gate on prompt and model changes**, so a prompt edit that regresses
      "leave clean text alone" fails the build.
- [ ] **Latency instrumentation** enforcing the p50/p95 budget.
- [ ] **A published benchmark table** comparing provider and prompt combinations.
      Nobody has a good public benchmark for dictation as opposed to
      transcription, and building one in the open is worth more than any feature
      on this list.

## Later — the other platforms

- [ ] **iOS.** The hard one, and the reason the core is portable. The container
      app owns the microphone and a keyboard extension triggers it over an App
      Group; the mic restriction is kernel-enforced and not negotiable. If the
      round trip feels bad, iOS ships as an app-first experience instead of a
      keyboard.
- [ ] **Windows.** A native shell over the same core: clipboard injection with
      save and restore, a low-level keyboard hook, UI Automation for context.
      The core already compiles and tests on Windows in CI so that this stays a
      UI project rather than a rewrite.

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
