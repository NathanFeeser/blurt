#!/usr/bin/env python3
"""DictBench — score the cleanup stage across configurations.

Drives the real `blurt cleanup` command rather than reimplementing the
prompt, so what gets scored is what ships. Cleanup is measured without audio on
purpose: STT latency on a free tier varies by a factor of three between
identical clips and would swamp the signal.

  ./run.py --efforts low,medium,high --reps 3
"""
import argparse, json, pathlib, re, subprocess, sys, time
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / "target" / "release" / "blurt"


def load_cases(path):
    return [json.loads(l) for l in open(path) if l.strip()]


# Groq's free tier allows 8,000 tokens per minute with the bucket refilling on a
# ~10s cadence, and 1,000 requests per day. Exponential backoff is the wrong
# shape for that: it sleeps far longer than the bucket needs. Pace proactively
# and retry on a fixed short interval instead.
TOKENS_PER_MIN = 8000
RETRY_SLEEP = 10.0


def run_case(case, effort, model, retries=10):
    cmd = [str(BIN), "cleanup", case["raw"], "--no-skip", "--reasoning-effort", effort]
    if model:
        cmd += ["--llm-model", model]
    if case.get("app"):
        cmd += ["--app", case["app"]]
    if case.get("context"):
        cmd += ["--context", case["context"]]

    for attempt in range(retries):
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            # Free-tier rate limiting surfaces as a non-zero exit.
            if "rate" in proc.stderr.lower() or "429" in proc.stderr:
                time.sleep(RETRY_SLEEP)
                continue
            return None, f"exit {proc.returncode}: {proc.stderr.strip()[:120]}"
        data = json.loads(proc.stdout)
        err = data.get("cleanup_error")
        if err and ("rate" in err.lower() or "limit" in err.lower()):
            time.sleep(RETRY_SLEEP)
            continue
        return data, err
    return None, "gave up after rate-limit retries"


def score(case, out):
    """Return (failures, checks_run). Each assertion is one check."""
    fails, checks = [], 0
    raw, final = case["raw"], out
    norm = " ".join(final.split())
    raw_norm = " ".join(raw.split())

    if case.get("unchanged"):
        checks += 1
        # Allow trivial punctuation drift; the point is that nothing was rewritten.
        if norm.rstrip(".").lower() != raw_norm.rstrip(".").lower():
            fails.append(f"rewrote clean text -> {final!r}")

    for needle in case.get("must_contain", []):
        checks += 1
        if needle.lower() not in final.lower():
            fails.append(f"missing {needle!r}")

    for needle in case.get("must_not_contain", []):
        checks += 1
        if needle.lower() in final.lower():
            fails.append(f"still contains {needle!r}")

    if pattern := case.get("must_match"):
        checks += 1
        if not re.search(pattern, final):
            fails.append(f"no match for /{pattern}/")

    if (floor := case.get("min_length_ratio")) is not None:
        checks += 1
        ratio = len(final) / max(1, len(raw))
        if ratio < floor:
            fails.append(f"too short: {ratio:.0%} of raw (floor {floor:.0%})")

    if (cap := case.get("max_length_ratio")) is not None:
        checks += 1
        ratio = len(final) / max(1, len(raw))
        if ratio > cap:
            fails.append(f"too long: {ratio:.0%} of raw (cap {cap:.0%})")

    return fails, checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=str(pathlib.Path(__file__).parent / "cases.jsonl"))
    ap.add_argument("--efforts", default="low,medium,high")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--model", default=None)
    ap.add_argument("--out", default=None, help="write raw results as JSON")
    ap.add_argument("--pace", type=float, default=None,
                    help="seconds between calls; default is estimated from the token budget")
    args = ap.parse_args()

    if not BIN.exists():
        sys.exit(f"build the CLI first: cargo build --release -p blurt-cli")

    cases = load_cases(args.cases)
    efforts = args.efforts.split(",")
    total = len(cases) * len(efforts) * args.reps
    print(f"{len(cases)} cases x {len(efforts)} efforts x {args.reps} reps = {total} calls\n")

    # Estimate tokens per call from the case text plus the system prompt, so the
    # run paces itself under the limit instead of discovering it by failing.
    approx = sum(len(c["raw"]) / 3 + 600 for c in cases) / len(cases)
    if "high" in efforts:
        approx += 500  # high effort spends ~500 reasoning tokens
    pace = args.pace if args.pace is not None else max(2.0, 60.0 * approx / TOKENS_PER_MIN)
    eta = total * pace / 60
    print(f"~{approx:.0f} tokens/call, pacing {pace:.1f}s apart to stay under "
          f"{TOKENS_PER_MIN} tok/min (ETA ~{eta:.0f} min)\n", flush=True)

    results = []
    done = 0
    for effort in efforts:
        for case in cases:
            for rep in range(args.reps):
                if done:
                    time.sleep(pace)
                data, err = run_case(case, effort, args.model)
                done += 1
                if data is None:
                    print(f"  [{done}/{total}] {case['id']:24} {effort:6} ERROR {err}", flush=True)
                    results.append({"case": case["id"], "category": case["category"],
                                    "effort": effort, "rep": rep, "error": err,
                                    "fails": ["error"], "checks": 1, "ms": None})
                    continue
                fails, checks = score(case, data["final_text"])
                results.append({"case": case["id"], "category": case["category"],
                                "effort": effort, "rep": rep,
                                "final": data["final_text"], "fails": fails,
                                "checks": checks, "ms": data["cleanup_ms"],
                                "error": data.get("cleanup_error")})
                mark = "ok  " if not fails else "FAIL"
                print(f"  [{done}/{total}] {case['id']:24} {effort:6} {mark} {data['cleanup_ms']:>5}ms"
                      + (f"  {fails[0]}" if fails else ""), flush=True)

    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(results, indent=2))

    report(results, cases, efforts)


def report(results, cases, efforts):
    print("\n" + "=" * 78)
    print("SUMMARY  (a check is one assertion; a case can carry several)")
    print("=" * 78)

    print(f"\n{'effort':8} {'checks passed':>16} {'cases clean':>14} {'median ms':>11} {'p90 ms':>9}")
    for effort in efforts:
        rows = [r for r in results if r["effort"] == effort]
        checks = sum(r["checks"] for r in rows)
        failed = sum(len(r["fails"]) for r in rows)
        clean = sum(1 for r in rows if not r["fails"])
        times = sorted(r["ms"] for r in rows if r["ms"] is not None)
        med = times[len(times) // 2] if times else 0
        p90 = times[int(len(times) * 0.9)] if times else 0
        print(f"{effort:8} {checks-failed:>7}/{checks:<8} {clean:>7}/{len(rows):<6} {med:>11} {p90:>9}")

    print(f"\n{'category':18}" + "".join(f"{e:>12}" for e in efforts))
    cats = sorted({c["category"] for c in cases})
    for cat in cats:
        line = f"{cat:18}"
        for effort in efforts:
            rows = [r for r in results if r["effort"] == effort and r["category"] == cat]
            checks = sum(r["checks"] for r in rows)
            failed = sum(len(r["fails"]) for r in rows)
            line += f"{checks-failed:>6}/{checks:<5}"
        print(line)

    print("\nFailures by case (any effort):")
    seen = defaultdict(list)
    for r in results:
        for f in r["fails"]:
            seen[(r["case"], r["effort"])].append(f)
    if not seen:
        print("  none")
    for (case_id, effort), fs in sorted(seen.items()):
        print(f"  {case_id:24} {effort:6} {fs[0]}")


if __name__ == "__main__":
    main()
