# Contributing to Blurt

Thanks for looking. This document is meant to get you from a fresh clone to a
merged change without having to reverse-engineer anyone's preferences.

## Getting set up

You need macOS 13+, [Rust](https://rustup.rs) (stable), and Xcode 16 or newer.
Nothing else — no package manager, no `.xcodeproj`.

```bash
./scripts/build-macos-app.sh --run   # core + bindings + app, then launch it
./scripts/build-xcframework.sh       # just the Rust core as an XCFramework
./scripts/swift-smoke.sh             # exercises the Rust <-> Swift boundary
cargo test --all                     # 95 core tests
swift test --package-path apps/macos # 80 app tests
```

`swift-smoke.sh` is not part of the app build, so run it after changing anything
on the UniFFI boundary. Adding a field to a core record breaks it on purpose:
the smoke test constructs those records by hand, which makes a change to the
boundary a compile error somewhere you will notice rather than a surprise in a
shell you were not thinking about.

`build-macos-app.sh` always rebuilds the Rust core and regenerates the Swift
bindings. That is deliberate: stale FFI bindings fail in confusing ways, and
cargo already no-ops when nothing changed. Set `BLURT_SKIP_TESTS=1` to skip the
test run during a tight edit loop, and `BLURT_SIGN_IDENTITY` to a stable
certificate so macOS stops treating each rebuild as a new app and re-prompting
for permissions.

What it builds is **Blurt Dev**, `com.nerflabs.blurt.dev` — a different app
from the one in Releases, on purpose. macOS keys every kind of trust on bundle
id plus signature, and a local build is signed differently from a release, so
sharing one id meant the two fought over keychain items, Accessibility grants,
Sparkle's update state and the history database. With separate ids they share
nothing but the hotkey: their own permissions (granted once each), their own
preferences, their own API keys, `~/Library/Logs/Blurt.dev.log` instead of
`Blurt.log`, and both can run at the same time. Everything the app owns on
disk or in a system database derives its name from `AppIdentity`, never from
a literal — keep it that way.

## Where things live

```
crates/blurt-core/    the pipeline. No UI, no OS assumptions, no vendor assumptions.
crates/blurt-cli/     `blurt` — the same pipeline from a terminal.
apps/macos/Sources/BlurtKit/    all the macOS logic, so it can be tested
apps/macos/Sources/Blurt/       a nine-line entry point that does nothing else
eval/                 DictBench — cases, runner, findings
docs/ARCHITECTURE.md  why the core is portable and what the shells own
```

**The one rule that shapes everything:** if a piece of logic could exist on
Windows, it belongs in the Rust core. The shells own capture, the hotkey,
context scraping, and text insertion, and nothing else. When you find yourself
writing pipeline logic in Swift, that is the signal you are in the wrong file —
the same code would have to be written again for Windows, which is exactly the
trap this architecture exists to avoid.

## A worked example: adding a transcription provider

The most self-contained way in. Say you want to add ElevenLabs.

1. **Decide whether it needs an adapter at all.** Most providers speak the
   OpenAI wire format, and those need no new code — add the id to
   `SttKind::from_id` and a default endpoint to `default_base_url`, both in
   `crates/blurt-core/src/providers/mod.rs`. That is the entire change, and it
   is how Groq, Ollama, LM Studio, and vLLM are supported.
2. **If the API genuinely differs**, implement `SttProvider` in
   `providers/stt.rs`, next to `DeepgramStt` which exists for the same reason.
   The trait takes an `SttRequest` — raw samples, not an encoded file, because
   each provider owns its own wire format and encoding a WAV for a provider that
   immediately decodes it is pure waste.
3. **Wire it into `build_stt`** in `engine.rs`.
4. **Test it without the network.** Provider tests cover request construction
   and response parsing, not live calls; a test suite that needs an API key is a
   test suite that does not run in CI.
5. **Add it to the README's provider table** and to the settings UI's known
   provider list.

The same shape applies to cleanup models via `LlmProvider`.

## Tests

Roughly: **the core is where the logic is, so the core is where the tests are.**
The app's tests cover the pure decisions that got extracted specifically so they
could be tested — gesture recognition, mode resolution, undo eligibility,
microphone classification.

A test should pin down a decision someone might otherwise undo by accident. The
most valuable tests in this repo are the ones whose names read as claims about
behaviour: `on_device_never_falls_back_to_a_hosted_provider`,
`a_mode_that_opts_out_is_never_recorded`, `refuses_once_the_user_has_switched_apps`.

Things that are hard to test honestly — CoreAudio, Accessibility, live APIs —
get a thin uninteresting wrapper around a pure function, and the pure function
gets the test.

## Style

- **Comments explain why, never what.** The code says what it does. A comment
  earns its place by recording a decision, a measurement, or a trap — including
  the ones that were paid for in debugging time.
- **Follow the surrounding file.** Comment density and naming vary a little
  between modules; match what is already there.
- `cargo fmt` and `swift-format` conventions are enforced in CI, along with
  `clippy -D warnings`.
- **Commit messages explain the change to someone who was not there.** Subject
  in the imperative; a body that says what was wrong, what was measured, and why
  the fix is shaped the way it is. `git log` is the project's real design
  documentation.

## Changes that need discussion first

Open an issue before writing code if you are planning to:

- Add a dependency to `blurt-core`. It is the piece that has to cross-compile to
  three platforms; every dependency is a future cross-compilation problem. There
  are currently very few, and the ones present were chosen for that reason (see
  the notes in `crates/blurt-core/Cargo.toml`).
- Change the UniFFI surface. Three shells will eventually depend on it, so it is
  cheap to change now and expensive later.
- Anything on the "Not planned" list in [ROADMAP.md](ROADMAP.md). Not a no — but
  the reasoning there is load-bearing and worth arguing with explicitly.

## Reporting a quality problem

The most useful bug reports for a dictation app include what you said, what came
out, and which mode ran. **Settings → History** has all three — it keeps the raw
transcript next to the cleaned-up text, which immediately separates a
transcription problem from a cleanup problem. `~/Library/Logs/Blurt.log` has the
microphone, the timings, and the provider.

Please redact anything private before pasting; history holds real dictation.

## Decisions already made

[docs/DECISIONS.md](docs/DECISIONS.md) records what was decided and what
evidence decided it. Before reopening a settled architectural question, check
whether it is in there. If the reasoning is wrong, that is worth
knowing; if the evidence has changed, that is worth knowing too. Either way the
argument starts from what was already measured.
