# Architecture

## The one decision everything else hangs off

freeflow is macOS-only *because* its pipeline lives inside a 3,414-line SwiftUI `AppState`.
If we want macOS + iOS + Windows, the pipeline has to be a library that knows nothing about
any UI framework.

**Decision (2026-08-24): a portable Rust core (`blurt-core`) with thin native shells.**

```
                    ┌─────────────────────────────────────────┐
                    │            blurt-core (Rust)         │
                    │                                         │
   audio frames ───►│  ring buffer + pre-roll                 │
                    │  VAD / endpointing                      │
                    │  encode (opus/wav)                      │
                    │  ┌───────────────────────────────────┐  │
                    │  │ provider registry                 │  │
                    │  │  stt:  groq | deepgram | eleven   │  │
                    │  │        | openai-compat | local    │  │
                    │  │  llm:  any openai-compat          │  │
                    │  └───────────────────────────────────┘  │
                    │  cleanup pipeline (prompt assembly)     │
                    │  vocabulary + learned corrections       │
                    │  modes / settings schema                │
                    │  history store (sqlite)                 │
                    │                                         │
                    └──────┬──────────────┬──────────────┬────┘
                     UniFFI│         UniFFI│           C ABI│
                    ┌──────▼─────┐  ┌──────▼─────┐  ┌───────▼──────┐
                    │  macOS app │  │  iOS app + │  │ Windows app  │
                    │  (SwiftUI) │  │  keyboard  │  │ (WinUI/C# or │
                    │            │  │  extension │  │  Rust+egui)  │
                    └────────────┘  └────────────┘  └──────────────┘
```

Each shell owns **only** the things that are irreducibly platform-specific:

| Concern | macOS | iOS | Windows |
|---|---|---|---|
| Audio capture | AVAudioEngine | AVAudioSession (container app only) | WASAPI |
| Global hotkey | CGEventTap / `NSEvent` monitor | n/a (keyboard button) | low-level keyboard hook + watchdog |
| Text insertion | AX first, clipboard+⌘V fallback | `textDocumentProxy.insertText` | clipboard + Ctrl+V (save/restore) |
| Screen context | Accessibility API | n/a | UI Automation |
| Local inference | WhisperKit (CoreML/ANE) | WhisperKit | whisper.cpp / ONNX+DirectML |
| Updates | Sparkle | App Store | MSIX / Squirrel |

### Why Rust and not "Swift core + Windows rewrite"

The Swift-first alternative is genuinely faster to week-one ship: SwiftPM package shared
between the macOS and iOS targets, no FFI, no toolchain plumbing, and the entire on-device
model story (WhisperKit) is already Swift. The cost is that Windows becomes a from-scratch
reimplementation of the pipeline, which is exactly the trap freeflow is in.

Rust costs maybe 1–2 weeks of upfront setup (UniFFI bindings, xcframework build, CI matrix)
and forces a small amount of FFI awkwardness at the audio boundary. It buys one
implementation of the thing that will contain all the interesting logic.

**Decided: Rust core.** Windows is a real roadmap item, not an aspiration, so we pay the
setup cost once rather than reimplementing the pipeline in Phase 4. The Swift-first path is
recorded here as the road not taken; revisit only if Windows gets cut.

Practical consequences to plan around:
- Phase 0 gains ~1–2 weeks before first dogfood. Accept it; don't shortcut it.
- **Audio never crosses the FFI boundary per-frame.** Shells write PCM into a shared ring
  buffer the core owns; the core is handed a handle, not a stream of copied frames. Getting
  this wrong is the one way the Rust decision turns into a latency problem.
- **On-device inference stays native.** WhisperKit is Swift/CoreML and stays in the macOS/iOS
  shells behind a core-defined `LocalSTT` trait. The core orchestrates; it does not try to own
  the Neural Engine.
- Toolchain to stand up in week 1: `cargo` workspace, UniFFI + `uniffi-bindgen-swift`,
  an xcframework build script, and CI on macOS/iOS/Windows targets.

Either way: **the pipeline is a library with its own tests and its own CLI.** A
`blurt transcribe file.wav --mode email` command that runs the exact production path is
what makes the eval harness possible at all.

## Latency budget

This is the product. Wispr feels instant; anything over ~1s of dead air after you stop
speaking feels broken. Target: **p50 ≤ 600 ms, p95 ≤ 1.2 s** from hotkey release to text on
screen, for a 5-second utterance.

Naive serial pipeline:

```
release ──► upload 5s clip (80–150ms) ──► STT (250–500ms) ──► LLM cleanup (300–800ms) ──► insert (20ms)
            └────────────────────────── 650ms – 1.5s ──────────────────────────────────┘
```

Three moves get us under budget:

1. **Overlap the network with the speech.** Stream audio to STT *while the user is talking*,
   so STT finishes ~150–300 ms after release instead of starting then. This alone removes the
   upload and most of the STT time from the critical path. Costs more (streaming tiers are
   ~5–10x batch) — make it a per-mode setting, batch by default, streaming for the managed
   tier and for anyone who opts in.
2. **Make cleanup skippable and small.** Most utterances need only filler-removal and
   punctuation. Run a cheap classifier (or a length/heuristic gate) and skip the LLM hop
   entirely when the raw transcript is already clean. When it does run, use the smallest model
   that passes eval, stream its output token-by-token, and insert incrementally.
3. **Pre-roll ring buffer.** Keep ~250 ms of mic audio buffered at all times so the first
   syllable isn't clipped when the hotkey fires. Cheap, and it removes a whole class of
   "it missed my first word" complaints.

### Measured baseline (2026-08-24, Groq, batch STT, from a laptop)

12 runs of `blurt transcribe` on 4 TTS clips, release build, warm connection:

| Path | STT | Cleanup | Total |
|---|---|---|---|
| Skip gate fired (clean input) | 444–531 ms | 0 | **444–531 ms** |
| Cleanup ran | 515–921 ms | 416–613 ms | **969–1420 ms** |

Aggregate: **p50 ≈ 750 ms, p95 ≈ 1.42 s** — over the 600 ms / 1.2 s budget, and
over it for exactly the predicted reason: batch STT puts the whole upload and
transcription on the critical path *after* the user stops talking.

The load-bearing detail is that STT latency barely tracks audio length — 461 ms
for a 1.9 s clip versus 552 ms for a 5.1 s clip. That time is network round-trip
and fixed provider overhead, not transcription work. So streaming during speech
should remove nearly all of it rather than merely some of it, which is what makes
move (1) above worth its cost. The skip-gate path already sits inside budget
today, which is the other half of the argument for move (2).

### In-app measurements (2026-08-24, real dictation on Groq's free tier)

13 dictations through the macOS app, hold-to-talk and hands-free:

| | |
|---|---|
| Audio engine start (on-demand mic) | 78–105 ms, mean ~90 ms |
| Short dictation, skip gate fired | 320–538 ms total |
| Longer dictation, cleanup ran | 2.0–2.9 s total |

Two corrections to the estimates above:

**Opening the microphone on the hotkey costs ~90 ms, not the 100–300 ms assumed.**
That is cheap enough that the always-listening design was not worth its cost —
see the note in `AudioEngine.swift`. The core's pre-roll ring is consequently
inert on macOS today.

**STT latency does scale with audio length, contrary to the batch measurements
above** — those used 2–5 s clips where fixed overhead dominates. A 29 s
hands-free recording took 1177 ms of STT. But the variance is large enough
(a 7 s clip took 1979 ms in the same session) that free-tier scheduling, not
audio length, is the dominant term. Do not tune against these numbers without a
paid tier.

Short dictations already sit inside the p50 budget. The cleanup path does not,
and that gap is what Phase 1 streaming is for.

Re-measure after Phase 1 streaming lands. If p50 is not under 600 ms then, the
budget is wrong or the design is.

The long game (Phase 6) collapses two hops into one: a single audio-native model that goes
raw audio → final formatted text. That's where a trained model actually pays for itself.

## The cleanup stage

This is the quality differentiator, and it's a prompt + context problem before it's a model
problem. Inputs assembled by the core:

- raw ASR transcript (plus alternates/confidence when the provider gives them)
- **active mode** — system prompt, tone, formatting rules
- **app context** — frontmost app bundle id, window title, and scraped nearby text via AX/UIA.
  This is what fixes proper nouns and matches surrounding style. Most of the perceived
  intelligence lives here.
- **user vocabulary** — explicit terms + terms learned from past corrections
- **recent history** — last few utterances, so "no, scratch that" works across turns

Behaviors it must handle (these become eval cases, see below):
filler removal · punctuation and capitalization · self-corrections ("Tuesday, wait no, Friday")
· spoken formatting commands ("new line", "bullet point") · list/paragraph structure ·
proper-noun spelling from context · tone matching per app · code-awareness in editors ·
leaving already-correct text alone (the most common failure mode is over-editing).

## Audio input

The microphone is the highest-leverage part of the pipeline and the only part
another application can change behind the user's back. macOS hands a Bluetooth
headset's mic over in hands-free mode — narrowband, compressed, and aggressively
noise-gated — and the gate is the real damage: it removes quiet syllables
outright, so transcripts come back with holes and the model hallucinates to fill
them. Measured 2026-08-25: identical prompts, once through the built-in array and
once through connected earbuds, with the second producing transcripts missing
words mid-sentence, and swapping on-device WhisperKit for Groq changing nothing —
because the words were never in the signal.

So the shell pins a device rather than following the system default
(`kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit), names
it in the recording overlay, the menu, and the log, and flags a Bluetooth or
sub-16 kHz input once per device. 16 kHz itself is not flagged: it is exactly
what transcription wants, and warning about it would train the user to ignore
the warning.

The lesson generalises past macOS. Every shell will have a version of this, and
"the model got worse" is what a degraded input looks like from the outside —
which is why DictBench needs audio-level cases (see ROADMAP.md) rather than
text-only ones.

## History

Implemented 2026-08-25. `crates/blurt-core/src/history.rs` — SQLite in the core rather
than one store per shell, so there is a single schema and a history file written on a Mac
reads on Windows. The core writes the row itself at the end of `transcribe`/`run_command` and
returns its id on `DictationResult`; the shell annotates it afterwards with the insertion
method, which only the shell can know.

**Text only. No audio is written to disk, ever.** That is what makes the privacy sentence
short enough to say to someone who is about to grant accessibility access, and it is the
reason "re-run" means re-running *cleanup* over the stored transcript rather than
re-transcribing. Trying a different prompt on what you actually said is the useful half:
it is how a user decides whether a mode is worth switching to.

Three controls, because this is a plaintext record of everything the user dictates:

| Control | Where |
|---|---|
| Master switch | Settings → History. Off closes the store, so the core has nowhere to write. |
| Per-mode `record_history` | Mode editor. Off for the Private preset — a mode whose point is that nothing leaves the machine should not leave a transcript of it either. |
| Retention cap | Enforced on every write, so the file cannot grow unwatched. `clear` also `VACUUM`s: deleted text that stays recoverable in free pages is not what "clear my history" means. |

The `edited_text` column is written by nothing today. It is the `(final text → what the user
actually kept)` correction pair that Phase 6 trains on, and adding it later would mean
migrating everyone's history.

Undo lives in the shell (`TextInserter.undoPlan`) because it is entirely platform-specific.
The rule: remove exactly the inserted text when the focused field still ends with it; fall
back to ⌘Z when the field cannot be read; refuse once the frontmost app has changed. That
last case is the one that matters — a ⌘Z sent into the wrong window destroys work the user
did themselves, so it is a pure function with tests rather than a judgement made inline.

## Evaluation: `DictBench`

Nobody has a good public benchmark for *dictation* as opposed to *transcription*. WER over
read speech says nothing about whether cleanup mangled your meaning. Building this in the
open is both the thing that makes our quality real and the best marketing artifact we have.

Structure: a set of `(audio, app_context, mode, vocabulary) → expected_text` cases, with
graders for exact-match on formatting-sensitive cases and an LLM judge (rubric: meaning
preserved, no hallucinated content, formatting correct, corrections applied) for the rest.
Seed it from our own dogfooding via the pipeline-history export path, plus recorded cases for
each behavior above.

**LangSmith fits here** — dataset versioning, experiment comparison across model/prompt
combos, and trace inspection when a case regresses. It does *not* belong in the client hot
path: it's Python, it's a network hop, and the app is a BYOK on-device binary. Same for
LangChain — the client should call providers directly over plain HTTP; the eval harness and
(later) the managed backend are where the framework earns its keep.

Run the harness in CI on every prompt change. A prompt edit that regresses "leaves clean text
alone" from 94% to 81% should fail the build.

## Privacy model

- Keys in the OS keychain (Keychain Services / Windows Credential Manager). Never in
  `UserDefaults`, never in plaintext config, never logged.
- Audio is held in memory and never written to disk. History keeps text only — see above.
- **Zero telemetry by default.** Opt-in, granular, and the payload is inspectable in the UI.
- The data flywheel — donating (audio, raw ASR, final text after user edits) — is strictly
  opt-in with a visible indicator, because those user edits are exactly the gold labels a
  fine-tune needs. Ask honestly, make it easy to say no, and make the donated corpus's
  license explicit up front.
