#!/usr/bin/env python3
"""Score every archived trial and rank the models.

compare-models varies the model; the agent and platform are fixed controls. So
the ranking metric is correctness, not speed (VISION.md): the anchor pass rate
-- one frozen suite, never shown to the model, identical for every trial -- is
PRIMARY, and clean-completion rate is CO-PRIMARY. Wall-clock time, tokens, and
turns are the explanatory layer and never reorder the ranking.

The cross-matrix asks whether a binary survives a suite it was not written
against; the catch rate exposes a run that games the task with trivial tests.
Those are task-integrity checks, independent of which model produced a trial.

Results are read from results/<target>/<agent>/ -- the platform and agent are
fixed per evaluation (see harness/lib.sh), so scoring honors TARGET and AGENT
the same way the harness does.
"""

import argparse
import concurrent.futures
import json
import os
import pathlib
import statistics
import subprocess

REPO = pathlib.Path(__file__).resolve().parent.parent
TARGET = os.environ.get("TARGET", "dgx")
AGENT = os.environ.get("AGENT", "omp")
RESULTS = REPO / "results" / TARGET / AGENT
TRIALS_DIR = RESULTS / "trials"
ANCHOR_DIR = REPO / "spec" / "anchor"
REFERENCE_BIN = REPO / "spec" / "reference" / "pngdec-reference"
SUITE_TIMEOUT = 300


def leaf_results(go_test_json: str) -> dict[str, bool]:
    """Map leaf test name to pass/fail from `go test -json` output.

    Parent tests are dropped: a parent's verdict merely restates its subtests.
    """
    outcomes: dict[str, bool] = {}
    for line in go_test_json.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = event.get("Test")
        action = event.get("Action")
        if not name or action not in ("pass", "fail"):
            continue
        outcomes[name] = action == "pass"
    names = set(outcomes)
    return {n: ok for n, ok in outcomes.items()
            if not any(other.startswith(n + "/") for other in names)}


def run_suite(suite_dir: pathlib.Path, binary: pathlib.Path) -> tuple[bool, dict[str, bool]]:
    """Run one trial's suite against one binary. Returns (all_passed, per-test)."""
    env = dict(os.environ, PNGDEC_BIN=str(binary.resolve()))
    try:
        proc = subprocess.run(
            ["go", "test", "-count=1", "-json", "./..."],
            cwd=suite_dir, env=env, capture_output=True, text=True,
            timeout=SUITE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return False, {}
    results = leaf_results(proc.stdout)
    return (proc.returncode == 0 and bool(results)), results


def median_iqr(values: list[float]) -> dict:
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return {"median": None, "q1": None, "q3": None, "n": 0}
    if len(vals) < 4:
        return {"median": statistics.median(vals), "q1": None, "q3": None, "n": len(vals)}
    q1, _, q3 = statistics.quantiles(vals, n=4)
    return {"median": statistics.median(vals), "q1": q1, "q3": q3, "n": len(vals)}


def _evaluations_with_trials() -> list[tuple[str, str]]:
    """Every results/<target>/<agent> that actually holds scored-able trials."""
    root = REPO / "results"
    found = []
    if root.is_dir():
        for target_dir in sorted(p for p in root.iterdir() if p.is_dir()):
            for agent_dir in sorted(p for p in target_dir.iterdir() if p.is_dir()):
                td = agent_dir / "trials"
                if td.is_dir() and any((d / "meta.json").is_file()
                                       for d in td.iterdir() if d.is_dir()):
                    found.append((target_dir.name, agent_dir.name))
    return found


def _wrong_evaluation_hint() -> str:
    """When the requested TARGET/AGENT has no trials, point at ones that do.

    `make score` with no args uses the Makefile defaults (dgx/omp), which is the
    most common way to end up scoring an empty evaluation right after running a
    batch under a different TARGET/AGENT.
    """
    others = [(t, a) for (t, a) in _evaluations_with_trials()
              if (t, a) != (TARGET, AGENT)]
    if not others:
        return (f"(scoring TARGET={TARGET} AGENT={AGENT}; run a batch first, "
                f"e.g. `make run-all TARGET={TARGET} AGENT={AGENT}`.)")
    lines = [f"(scoring TARGET={TARGET} AGENT={AGENT} -- the Makefile defaults are "
             "dgx/omp; pass TARGET/AGENT to match your run.)",
             "Evaluations that DO have trials:"]
    lines += [f"  make score TARGET={t} AGENT={a}" for (t, a) in others]
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6,
                    help="parallel suite runs on the driver")
    ap.add_argument("--threshold", type=float, default=0.80,
                    help="anchor pass rate a trial's binary must reach to count "
                         "as a finished solution (default 0.80 = 26 of 32 cases)")
    args = ap.parse_args()

    if not REFERENCE_BIN.is_file():
        raise SystemExit(
            f"{REFERENCE_BIN} does not exist; run `make anchor-selftest` first. "
            "Without it every trial's suite_over_strict would be indistinguishable "
            "from a real finding rather than a missing binary.")

    trials = []
    excluded = []
    entries = sorted(TRIALS_DIR.iterdir()) if TRIALS_DIR.is_dir() else []
    for d in entries:
        if not (d / "meta.json").is_file():
            continue
        meta = json.loads((d / "meta.json").read_text())
        if not (d / "telemetry.json").is_file():
            excluded.append({"trial_id": meta["trial_id"], "model_id": meta.get("model_id"),
                             "reason": "telemetry.json missing (trial interrupted between "
                                       "meta.json and telemetry write)"})
            continue
        telemetry = json.loads((d / "telemetry.json").read_text())
        # Trial 00 is by convention a shakedown run, never scored.
        if meta["trial_id"].endswith("-00"):
            excluded.append({"trial_id": meta["trial_id"], "model_id": meta.get("model_id"),
                             "reason": "shakedown trial"})
            continue
        if telemetry["void"]:
            excluded.append({"trial_id": meta["trial_id"], "model_id": meta.get("model_id"),
                             "reason": f"void: {telemetry['void_reason']}"})
            continue
        trials.append({"dir": d, "meta": meta, "telemetry": telemetry})

    if not trials:
        raise SystemExit(f"no scorable trials in {TRIALS_DIR}\n"
                         + _wrong_evaluation_hint())

    caps = {t["meta"]["max_time"] for t in trials}
    if len(caps) > 1:
        raise SystemExit(f"trials were run at different time caps: {caps}; "
                         "the cap is a control and results are not comparable")

    # Anchor pass rate, from the per-trial anchor.json written by trial.sh.
    for t in trials:
        results = leaf_results((t["dir"] / "anchor.json").read_text())
        t["anchor"] = results
        t["anchor_total"] = len(results)
        t["anchor_pass"] = sum(1 for ok in results.values() if ok)

    anchor_totals = {t["anchor_total"] for t in trials if t["anchor_total"]}
    if len(anchor_totals) > 1:
        raise SystemExit(f"anchor suite case count differs between trials: {anchor_totals}; "
                         "the suite was edited mid-experiment and results are not comparable")

    # Cross-matrix: every binary against every suite, including its own.
    jobs = [(b, s) for b in trials for s in trials]
    matrix: dict[str, dict[str, bool]] = {t["meta"]["trial_id"]: {} for t in trials}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(run_suite, s["dir"] / "tree", b["dir"] / "pngdec"): (b, s)
            for b, s in jobs
        }
        for fut in concurrent.futures.as_completed(futures):
            b, s = futures[fut]
            passed, _ = fut.result()
            matrix[b["meta"]["trial_id"]][s["meta"]["trial_id"]] = passed

    # A suite that fails our own reference is over-strict: it asserts something
    # REQUIREMENTS.md does not require, so its catch rate is not evidence.
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        ref_futures = {
            pool.submit(run_suite, t["dir"] / "tree", REFERENCE_BIN): t for t in trials
        }
        for fut in concurrent.futures.as_completed(ref_futures):
            t = ref_futures[fut]
            passed, results = fut.result()
            t["suite_portable"] = bool(results)
            t["suite_over_strict"] = bool(results) and not passed

    for t in trials:
        tid = t["meta"]["trial_id"]
        own = matrix[tid]
        others = [v for k, v in own.items() if k != tid]
        t["cross_pass_rate"] = sum(own.values()) / len(own)
        t["cross_pass_rate_excl_self"] = (sum(others) / len(others)) if others else None
        caught = [not matrix[other["meta"]["trial_id"]][tid]
                  for other in trials if other["meta"]["trial_id"] != tid]
        t["catch_rate"] = (sum(caught) / len(caught)) if caught else None

    rows = []
    for t in trials:
        m, tel = t["meta"], t["telemetry"]
        anchor_rate = (t["anchor_pass"] / t["anchor_total"]) if t["anchor_total"] else 0.0
        finished = tel["completed_unassisted"] and anchor_rate >= args.threshold
        rows.append({
            "trial_id": m["trial_id"],
            "model_id": m["model_id"],
            "model": m.get("model"),
            "finished": finished,
            "wall_seconds": m["wall_seconds"],
            "time_to_finished_seconds": m["wall_seconds"] if finished else None,
            "anchor_pass": t["anchor_pass"],
            "anchor_total": t["anchor_total"],
            "anchor_rate": anchor_rate,
            "cross_pass_rate": t["cross_pass_rate"],
            "cross_pass_rate_excl_self": t["cross_pass_rate_excl_self"],
            "catch_rate": t["catch_rate"],
            "suite_portable": t["suite_portable"],
            "suite_over_strict": t["suite_over_strict"],
            "agent_exit": m["agent_exit"],
            "build_exit": m["build_exit"],
            "test_exit": m["test_exit"],
            "turns": tel["turns"],
            "tool_calls": tel["tool_calls"],
            "turns_before_first_edit": tel["turns_before_first_edit"],
            "tokens_input": tel["tokens_input"],
            "tokens_output": tel["tokens_output"],
            "tokens_total": tel["tokens_total"],
            "compactions": tel["compactions"],
            "completed_unassisted": tel["completed_unassisted"],
        })

    metrics = ["anchor_rate", "time_to_finished_seconds", "wall_seconds",
               "cross_pass_rate_excl_self", "catch_rate", "turns", "tool_calls",
               "turns_before_first_edit", "tokens_input", "tokens_output",
               "compactions"]

    # Group by model (the variable). Model order for display: the order they
    # appear on disk, but the ranking table below is ordered by correctness.
    model_ids = []
    for r in rows:
        if r["model_id"] not in model_ids:
            model_ids.append(r["model_id"])

    by_model = {}
    for mid in model_ids:
        mr = [r for r in rows if r["model_id"] == mid]
        by_model[mid] = {
            "n": len(mr),
            "voided": sum(1 for e in excluded
                          if e.get("model_id") == mid and e["reason"].startswith("void")),
            "completed_unassisted_rate": (
                sum(1 for r in mr if r["completed_unassisted"]) / len(mr)) if mr else None,
            "finished_rate": (
                sum(1 for r in mr if r["finished"]) / len(mr)) if mr else None,
            **{m: median_iqr([r[m] for r in mr]) for m in metrics},
        }

    def rank_key(mid: str) -> tuple:
        s = by_model[mid]
        anchor = s["anchor_rate"]["median"]
        comp = s["completed_unassisted_rate"]
        # Primary: anchor rate (correctness). Co-primary: completion rate.
        # Tie-break: faster median time (None sorts last). All descending, so
        # negate; missing values sort worst.
        return (
            -(anchor if anchor is not None else -1),
            -(comp if comp is not None else -1),
            (s["time_to_finished_seconds"]["median"]
             if s["time_to_finished_seconds"]["median"] is not None else float("inf")),
        )

    ranking = sorted(model_ids, key=rank_key)
    n_min = min((by_model[m]["n"] for m in model_ids), default=0)

    out = {"target": TARGET, "agent": AGENT, "threshold": args.threshold,
           "trials": rows, "matrix": matrix, "by_model": by_model,
           "ranking": ranking, "excluded": excluded}
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "scores.json").write_text(json.dumps(out, indent=2) + "\n")

    def fmt(v, digits=2):
        return "-" if v is None else f"{v:.{digits}f}"

    lines = [f"# Scores -- platform={TARGET} agent={AGENT}", "",
             f"Finished = completed unassisted AND anchor rate >= {args.threshold}.",
             "**Anchor rate (correctness) is the primary ranking metric; "
             "completion rate is co-primary. Time is explanatory.**", ""]
    if n_min <= 1:
        lines += ["> NOTE: at least one model has N<=1 trial. Single-run results "
                  "are INDICATIVE, not a ranking (VISION.md). Raise TRIALS for "
                  "trustworthy medians and rates.", ""]

    # Ranking table, ordered by correctness.
    lines += ["## Model ranking (by anchor rate, then completion rate)", "",
              "| rank | model | n | anchor rate | completed | finished | "
              "time to finished s | turns |", "|---|---|---|---|---|---|---|---|"]
    for i, mid in enumerate(ranking, 1):
        s = by_model[mid]
        lines.append(
            f"| {i} | {mid} | {s['n']} | {fmt(s['anchor_rate']['median'])} "
            f"| {fmt(s['completed_unassisted_rate'])} | {fmt(s['finished_rate'])} "
            f"| {fmt(s['time_to_finished_seconds']['median'], 0)} "
            f"| {fmt(s['turns']['median'], 0)} |")

    # Full per-model metric table.
    lines += ["", "## Per model (median, IQR where N>=4)", "",
              "| metric | " + " | ".join(ranking) + " |",
              "|" + "---|" * (len(ranking) + 1)]
    lines.append("| trials scored | " + " | ".join(str(by_model[m]["n"]) for m in ranking) + " |")
    lines.append("| trials voided | " + " | ".join(str(by_model[m]["voided"]) for m in ranking) + " |")
    lines.append("| completed unassisted | "
                 + " | ".join(fmt(by_model[m]["completed_unassisted_rate"]) for m in ranking) + " |")
    lines.append("| finished rate | "
                 + " | ".join(fmt(by_model[m]["finished_rate"]) for m in ranking) + " |")
    for metric in metrics:
        digits = 0 if metric in ("time_to_finished_seconds", "wall_seconds",
                                 "tokens_input", "tokens_output") else 2
        cells = []
        for m in ranking:
            st = by_model[m][metric]
            cells.append(f"{fmt(st['median'], digits)} ({fmt(st['q1'], digits)}-{fmt(st['q3'], digits)})")
        lines.append(f"| {metric} | " + " | ".join(cells) + " |")

    lines += ["", "## Per trial", "",
              "| trial | model | finished | wall s | anchor | cross (excl self) | catch "
              "| suite over-strict | turns | first-edit turn | tokens |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        first_edit = "-" if r["turns_before_first_edit"] is None \
            else str(r["turns_before_first_edit"])
        lines.append(
            f"| {r['trial_id']} | {r['model_id']} | {r['finished']} | {r['wall_seconds']:.0f} "
            f"| {r['anchor_pass']}/{r['anchor_total']} "
            f"| {fmt(r['cross_pass_rate_excl_self'])} | {fmt(r['catch_rate'])} "
            f"| {r['suite_over_strict']} | {r['turns']} | {first_edit} "
            f"| {r['tokens_total']} |")

    if excluded:
        lines += ["", "## Excluded", "", "| trial | model | reason |", "|---|---|---|"]
        lines += [f"| {e['trial_id']} | {e.get('model_id', '-')} | {e['reason']} |"
                  for e in excluded]

    text = "\n".join(lines) + "\n"
    (RESULTS / "scores.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
