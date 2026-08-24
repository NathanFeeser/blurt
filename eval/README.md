# DictBench

An eval suite for *dictation*, not transcription.

Every provider is at 2–5% WER now. What separates good dictation from great is
the cleanup stage: does it apply self-corrections, convert spoken formatting
commands, spell your colleagues' names right — and, most importantly, know when
to leave correct text alone. None of that shows up in WER.

## Running it

```bash
cargo build --release -p opendict-cli
./run.py                                    # low,medium,high x 3 reps
./run.py --efforts low,medium --reps 5      # narrower, more samples
./run.py --model qwen/qwen3.6-27b           # compare models
./run.py --out results.json                 # keep the raw results
```

The harness shells out to `opendict cleanup`, which runs the same
`pipeline::clean_up` the app uses. An eval that scores a reimplementation of the
prompt is scoring the wrong thing.

Cleanup is measured **without audio** on purpose. STT latency on a free tier
varies by a factor of three between identical clips and would swamp the signal.
Audio-level cases belong in a separate suite once there is a paid tier.

## Cases

`cases.jsonl`, one JSON object per line:

| field | meaning |
|---|---|
| `raw` | the transcript as ASR would produce it |
| `context` / `app` | simulated screen context |
| `unchanged` | output must equal input — the anti-over-editing check |
| `must_contain` / `must_not_contain` | case-insensitive substrings |
| `must_match` | regex |
| `min_length_ratio` / `max_length_ratio` | guards against summarising and padding |
| `why` | what regression this case protects against |

Every case exists because something actually broke, or because a rule in
`cleanup.rs` would otherwise be unenforced. Add a case whenever you notice a bad
dictation in real use — that is how this stays honest rather than synthetic.

## What it does not measure

The assertions are deterministic. They catch **behaviours** — was the correction
applied, was the command converted, was clean text left alone — but not style.
Whether cleanup preserved your voice or flattened it does not show up here, and
retention ratio is only a crude proxy for it. Judging that needs an LLM grader
with a rubric, which is the obvious next addition.

## Free-tier limits

Groq's free tier allows **8,000 tokens/minute** and **1,000 requests/day**. The
runner paces itself from an estimated tokens-per-call to stay under the former;
the latter is the real ceiling on how much evaluation is possible in a day. A
full 3-effort x 3-rep run over 21 cases is ~190 requests, so roughly five runs
per day. High reasoning effort roughly doubles token consumption and will hit
the per-minute limit regardless of pacing.
