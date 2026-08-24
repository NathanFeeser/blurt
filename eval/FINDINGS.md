# Findings

## 2026-08-24 — reasoning effort for the cleanup stage

21 cases x 3 efforts x 2 reps against `openai/gpt-oss-120b` on Groq.

| effort | checks passed | cases clean | median | p90 | mean retention |
|---|---|---|---|---|---|
| **low** | **112/112** | **42/42** | **697 ms** | 1592 ms | 78.0% |
| medium | 111/112 | 41/42 | 824 ms | 1423 ms | 79.0% |
| high | 50/68 | 24/42 | 1136 ms | 1476 ms | 69.7% |

**Verdict: keep `low`.**

Low and medium are indistinguishable on correctness — one check apart, and that
one was medium *failing* (`context-spelling` did not capitalise WhisperKit).
Mean retention differs by a single point, which is noise at n=36.

Per-case retention shows the two trading places rather than one dominating:
medium produced fuller bullet lists (`format-bullets`, 47% vs 31%) while low
preserved more of a numeric correction (`correct-number`, 58% vs 46%). Nothing
systematic.

**High could not be measured properly.** 18 of its 42 calls were rate-limited
out on the free tier, so its 50/68 is mostly missing data rather than wrong
answers. Where it did run, retention was markedly lower (69.7%) — it edits more
aggressively, which is the opposite of what this stage wants.

The intuition that more thinking should mean better cleanup does not hold here.
Cleanup is a formatting task; the reasoning budget is spent deliberating over
decisions the prompt has already made.

**Caveats.** Two reps per case is a small sample. More importantly, these
assertions measure behaviours, not voice — an earlier hand-check saw medium keep
"I was thinking we could ship on Friday" where low returned "We could ship
Friday", and no assertion here would notice that. If daily use suggests medium
reads better, that is real evidence this harness cannot produce, and the menu
setting exists precisely for that.

**Known case gap:** `filler-falsestart` originally used an em-dash, a written
convention ASR never emits. Rewritten to the verbatim repetition Whisper
actually produces.
