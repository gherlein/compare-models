#!/usr/bin/env python3
"""Compare scored model rankings across evaluations (different fixed agent or
platform), side by side.

VISION.md's central caveat is that every model ranking is conditional on the
fixed agent and platform -- a different agent or platform could reorder the
models. This tool makes that visible: give it two or more evaluations and it
prints, per model, the headline metrics for each, so a reordering jumps out. It
never recomputes anything -- it reformats what each evaluation's score.py
already wrote to results/<target>/<agent>/scores.json.

Each evaluation is named "<target>/<agent>" (the results namespace). Run
`make score TARGET=<t> AGENT=<a>` for each first.

Usage: compare.py <target>/<agent> <target>/<agent> [<target>/<agent> ...]
       compare.py                # defaults to dgx/omp dgx/hax
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# (json key in by_model, label, is_median_iqr, digits). Correctness first.
HEADLINE = [
    ("anchor_rate", "anchor rate (median)", True, 2),
    ("completed_unassisted_rate", "completed unassisted", False, 2),
    ("finished_rate", "finished rate", False, 2),
    ("time_to_finished_seconds", "time to finished s (median)", True, 0),
    ("wall_seconds", "wall s (median)", True, 0),
    ("tokens_output", "output tokens (median)", True, 0),
]


def load(spec: str) -> dict:
    target, _, agent = spec.partition("/")
    if not agent:
        sys.exit(f"evaluation '{spec}' must be '<target>/<agent>'")
    path = REPO / "results" / target / agent / "scores.json"
    if not path.exists():
        sys.exit(f"no scores for '{spec}': {path} missing "
                 f"(run `make score TARGET={target} AGENT={agent}` first)")
    return json.loads(path.read_text())


def cell(by_model: dict, mid: str, key: str, is_median: bool, digits: int) -> str:
    stats = by_model.get(mid)
    if not stats:
        return "-"
    value = stats.get(key)
    if is_median:
        value = (value or {}).get("median")
    return "-" if value is None else f"{value:.{digits}f}"


def main() -> None:
    specs = sys.argv[1:] or ["dgx/omp", "dgx/hax"]
    evals = {spec: load(spec) for spec in specs}

    # Union of all model ids across evaluations, in first-seen order.
    model_ids: list[str] = []
    for data in evals.values():
        for mid in data.get("by_model", {}):
            if mid not in model_ids:
                model_ids.append(mid)

    lines = ["# Model ranking across evaluations", "",
             "Per model, headline metrics for each evaluation side by side. A "
             "model that ranks differently under a different fixed agent or "
             "platform is exactly the conditionality VISION.md warns about. "
             "Values come verbatim from each results/<target>/<agent>/scores.json.",
             ""]
    for label_key, label, is_median, digits in HEADLINE:
        lines += [f"## {label}", "",
                  "| model | " + " | ".join(specs) + " |",
                  "|" + "---|" * (len(specs) + 1)]
        for mid in model_ids:
            cells = [cell(evals[s].get("by_model", {}), mid, label_key, is_median, digits)
                     for s in specs]
            lines.append(f"| {mid} | " + " | ".join(cells) + " |")
        lines.append("")

    text = "\n".join(lines)
    tag = "-vs-".join(s.replace("/", "_") for s in specs)
    out = REPO / "results" / f"compare-{tag}.md"
    out.write_text(text + "\n")
    print(text)
    print(f"\nwritten to {out}")


if __name__ == "__main__":
    main()
