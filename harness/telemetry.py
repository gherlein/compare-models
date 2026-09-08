#!/usr/bin/env python3
"""Extract per-trial telemetry from an agent session log.

The contamination check is the load-bearing part. omp falls back silently to
whatever provider it can still reach (measured in shakedown: the driver's
local ollama answered with a different model when the bench provider was
misconfigured), and nothing in the produced code reveals it. The provider and
model stamped on each session record do.

Each agent records sessions in its own format; one parser per agent maps both
onto the same telemetry shape so score.py never needs to know which agent
produced a trial.
"""

import argparse
import json
import pathlib
import re
from collections import Counter

# Tool names that mean the agent started producing code. Used for
# turns_before_first_edit: the number of model turns fully completed before
# the turn that made the first edit -- a planning-overhead proxy that is
# precisely extractable from both agents' logs, unlike wall-clock
# time-to-first-edit.
EDIT_TOOLS = {
    "omp": {"write", "edit", "ast-edit"},
    "hax": {"write", "edit"},
    "kit": {"write", "edit"},
    "pi": {"write", "edit"},
}

# hax's philosophy routes many capabilities through its bash tool, so an
# agent can make its first edit with a heredoc or a redirect rather than the
# write tool. Counting only tool-name edits would make the metric blind for
# one agent and not the other. This heuristic marks a bash command as a
# workspace edit when it redirects into a file; both parsers apply it so the
# definition stays identical across agents. It is a heuristic: a redirect to
# an unusual path shaped like an option could slip past, which is acceptable
# for a secondary planning-overhead metric.
_REDIRECT = re.compile(r"(<<|\btee\b|>>?\s*[\w./~'\"$])")


def bash_writes_file(command: str) -> bool:
    # Drop stderr redirects and null sinks first; `2> file` and `> /dev/null`
    # are not edits.
    cleaned = re.sub(r"\d?>{1,2}\s*(/dev/null|&\d)", " ", command)
    return bool(_REDIRECT.search(cleaned))


def load_records(paths: list[pathlib.Path]) -> list[dict]:
    records = []
    for path in paths:
        for line in path.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # A truncated final line happens when the external timeout
                # kills the agent mid-write. Dropping it is correct; failing
                # the whole trial over it is not.
                continue
    return records


def parse_omp(trial_dir: pathlib.Path) -> dict:
    session_dir = trial_dir / "session"
    paths = sorted(session_dir.rglob("*.jsonl")) if session_dir.is_dir() else []
    records = load_records(paths)

    assistants = [r for r in records
                  if r.get("type") == "message"
                  and r.get("message", {}).get("role") == "assistant"]

    totals = Counter()
    for r in assistants:
        usage = r["message"].get("usage") or {}
        totals["input"] += usage.get("input", 0)
        totals["output"] += usage.get("output", 0)
        totals["cacheRead"] += usage.get("cacheRead", 0)
        totals["cacheWrite"] += usage.get("cacheWrite", 0)
        totals["totalTokens"] += usage.get("totalTokens", 0)

    turns_before_first_edit = None
    assistants_seen = 0
    for r in records:
        if (r.get("type") == "message"
                and r.get("message", {}).get("role") == "assistant"):
            assistants_seen += 1
        elif (r.get("type") == "custom"
                and r.get("customType") == "tool_execution_start"):
            data = r.get("data", {})
            name = data.get("toolName")
            is_edit = name in EDIT_TOOLS["omp"] or (
                name == "bash"
                and bash_writes_file(str((data.get("args") or {}).get("command", ""))))
            if is_edit:
                # The assistant message that requested this edit is already
                # counted, and the edit belongs to that turn, not before it.
                turns_before_first_edit = max(0, assistants_seen - 1)
                break

    return {
        "has_records": bool(records),
        "turns": len(assistants),
        "tool_calls": sum(1 for r in records
                          if r.get("type") == "custom"
                          and r.get("customType") == "tool_execution_start"),
        "tokens_input": totals["input"],
        "tokens_output": totals["output"],
        "tokens_cache_read": totals["cacheRead"],
        "tokens_cache_write": totals["cacheWrite"],
        "tokens_total": totals["totalTokens"],
        "compactions": sum(1 for r in records if r.get("type") == "compaction"),
        "model_elapsed_ms": None,
        "turns_before_first_edit": turns_before_first_edit,
        "stop_reasons": dict(Counter(r["message"].get("stopReason")
                                     for r in assistants)),
        "provider_stamps": [r["message"].get("provider") for r in assistants],
        "model_stamps": [r["message"].get("model") for r in assistants],
    }


def parse_hax(trial_dir: pathlib.Path) -> dict:
    sessions_dir = trial_dir / "xdg" / "state" / "hax" / "sessions"
    paths = sorted(sessions_dir.rglob("*.jsonl")) if sessions_dir.is_dir() else []
    records = load_records(paths)

    usages = [r for r in records if r.get("kind") == "turn_usage"]

    totals = Counter()
    elapsed_ms = 0
    for r in usages:
        usage = r.get("usage") or {}
        totals["input"] += usage.get("input", 0)
        totals["output"] += usage.get("output", 0)
        elapsed_ms += usage.get("elapsed_ms", 0)

    turns_before_first_edit = None
    usages_seen = 0
    for r in records:
        kind = r.get("kind")
        if kind == "turn_usage":
            usages_seen += 1
        elif kind == "tool_call":
            name = r.get("tool_name")
            is_edit = name in EDIT_TOOLS["hax"]
            if not is_edit and name == "bash":
                try:
                    command = json.loads(r.get("arguments") or "{}").get("command", "")
                except json.JSONDecodeError:
                    command = ""
                is_edit = bash_writes_file(str(command))
            if is_edit:
                # turn_usage is written when a turn completes, after its tool
                # calls are recorded, so usages_seen is exactly the number of
                # turns finished before the turn that made this edit.
                turns_before_first_edit = usages_seen
                break

    # Model-turn records carry provider/model stamps; the session header does
    # too but only reflects the starting selection, so stamps come from the
    # per-turn records.
    return {
        "has_records": bool(records),
        "turns": len(usages),
        "tool_calls": sum(1 for r in records if r.get("kind") == "tool_call"),
        "tokens_input": totals["input"],
        "tokens_output": totals["output"],
        "tokens_cache_read": 0,
        "tokens_cache_write": 0,
        "tokens_total": totals["input"] + totals["output"],
        "compactions": sum(1 for r in records if r.get("kind") == "compact"),
        "model_elapsed_ms": elapsed_ms,
        "turns_before_first_edit": turns_before_first_edit,
        "stop_reasons": {},
        "provider_stamps": [r.get("provider") for r in usages],
        "model_stamps": [r.get("model") for r in usages],
    }


def parse_kit(trial_dir: pathlib.Path) -> dict:
    # kit (github.com/mark3labs/kit) writes an append-only JSONL session tree
    # under $HOME/.kit/sessions; the adapter redirects $HOME to $out/home, so
    # the session lands here. Each line is a typed entry (session/entry.go):
    # a "message" entry carries role, provider, model, and a "parts" array of
    # type-tagged blocks (text / reasoning / tool_call / tool_result / finish).
    sessions_dir = trial_dir / "home" / ".kit" / "sessions"
    paths = sorted(sessions_dir.rglob("*.jsonl")) if sessions_dir.is_dir() else []
    records = load_records(paths)

    assistants = [r for r in records
                  if r.get("type") == "message" and r.get("role") == "assistant"]

    def tool_calls_in(entry: dict) -> list[dict]:
        # parts is already a decoded list once the JSONL line is json.loads'd.
        out = []
        for part in entry.get("parts") or []:
            if isinstance(part, dict) and part.get("type") == "tool_call":
                out.append(part.get("data") or {})
        return out

    def is_edit_call(call: dict) -> bool:
        name = call.get("name")
        if name in EDIT_TOOLS["kit"]:
            return True
        # kit stores tool arguments as a JSON string in the "input" field.
        if name == "bash":
            try:
                command = json.loads(call.get("input") or "{}").get("command", "")
            except json.JSONDecodeError:
                command = ""
            return bash_writes_file(str(command))
        return False

    turns_before_first_edit = None
    assistants_seen = 0
    for r in records:
        if r.get("type") == "message" and r.get("role") == "assistant":
            assistants_seen += 1
            if turns_before_first_edit is None and any(
                    is_edit_call(c) for c in tool_calls_in(r)):
                # The tool_call lives inside this assistant message, so the edit
                # belongs to this turn (already counted): the number of turns
                # fully completed *before* it is assistants_seen - 1.
                turns_before_first_edit = max(0, assistants_seen - 1)

    stop_reasons = Counter()
    for r in assistants:
        for part in r.get("parts") or []:
            if isinstance(part, dict) and part.get("type") == "finish":
                stop_reasons[(part.get("data") or {}).get("reason")] += 1

    # kit does NOT persist per-turn token usage in its session JSONL (only
    # compaction entries carry tokens_before/after). trial.sh already snapshots
    # sglang's server-side prompt/generation counters around every agent run and
    # writes the delta to meta.json; since run-all runs trials strictly
    # sequentially, that delta is attributable to this trial. So kit's token
    # figures come from the server counter, not the session log. This is a
    # different source than omp/hax (which report model-side usage from their
    # logs): kit's tokens are server-side and include cache/retries, so they are
    # indicative, not strictly comparable. meta.json is absent during
    # config-smoke (no trial wrapper), so tokens are 0 there -- config-smoke
    # only asserts routing, not tokens.
    meta_path = trial_dir / "meta.json"
    server_delta = {}
    if meta_path.is_file():
        try:
            server_delta = json.loads(meta_path.read_text()).get("server_delta") or {}
        except (json.JSONDecodeError, OSError):
            server_delta = {}
    tokens_input = server_delta.get("prompt_tokens", 0) or 0
    tokens_output = server_delta.get("generation_tokens", 0) or 0

    return {
        "has_records": bool(records),
        "turns": len(assistants),
        "tool_calls": sum(len(tool_calls_in(r))
                          for r in records
                          if r.get("type") == "message"),
        "tokens_input": tokens_input,
        "tokens_output": tokens_output,
        "tokens_cache_read": server_delta.get("cached_tokens", 0) or 0,
        "tokens_cache_write": 0,
        "tokens_total": tokens_input + tokens_output,
        "compactions": sum(1 for r in records if r.get("type") == "compaction"),
        "model_elapsed_ms": None,
        "turns_before_first_edit": turns_before_first_edit,
        "stop_reasons": dict(stop_reasons),
        "provider_stamps": [r.get("provider") for r in assistants],
        "model_stamps": [r.get("model") for r in assistants],
    }


def parse_pi(trial_dir: pathlib.Path) -> dict:
    # pi (@earendil-works/pi-coding-agent) is the lean upstream omp forked, and
    # its session schema is almost identical to omp's: JSONL, assistant turns are
    # type=="message" with message.role=="assistant", stamped with
    # message.provider / message.model / message.usage.{input,output,cacheRead,
    # cacheWrite,totalTokens}. The one divergence is tool calls: omp writes a
    # separate type=="custom"/customType=="tool_execution_start" record, but pi
    # carries each tool call as a content block INSIDE the assistant message --
    # message.content[] item with {type:"toolCall", name, arguments} (arguments
    # is a decoded object, e.g. arguments.command for bash) -- and the result as
    # a separate message.role=="toolResult" message.
    session_dir = trial_dir / "session"
    paths = sorted(session_dir.rglob("*.jsonl")) if session_dir.is_dir() else []
    records = load_records(paths)

    assistants = [r for r in records
                  if r.get("type") == "message"
                  and r.get("message", {}).get("role") == "assistant"]

    def tool_calls_in(entry: dict) -> list[dict]:
        msg = entry.get("message") or {}
        return [c for c in (msg.get("content") or [])
                if isinstance(c, dict) and c.get("type") == "toolCall"]

    totals = Counter()
    for r in assistants:
        usage = r["message"].get("usage") or {}
        totals["input"] += usage.get("input", 0)
        totals["output"] += usage.get("output", 0)
        totals["cacheRead"] += usage.get("cacheRead", 0)
        totals["cacheWrite"] += usage.get("cacheWrite", 0)
        totals["totalTokens"] += usage.get("totalTokens", 0)

    def is_edit_call(call: dict) -> bool:
        name = call.get("name")
        if name in EDIT_TOOLS["pi"]:
            return True
        if name == "bash":
            # pi's tool arguments are a decoded object, not a JSON string.
            command = (call.get("arguments") or {}).get("command", "")
            return bash_writes_file(str(command))
        return False

    turns_before_first_edit = None
    assistants_seen = 0
    for r in records:
        if (r.get("type") == "message"
                and r.get("message", {}).get("role") == "assistant"):
            assistants_seen += 1
            if turns_before_first_edit is None and any(
                    is_edit_call(c) for c in tool_calls_in(r)):
                # The tool call is inside this assistant message, so the edit
                # belongs to this turn (already counted): turns completed before
                # it is assistants_seen - 1.
                turns_before_first_edit = max(0, assistants_seen - 1)

    return {
        "has_records": bool(records),
        "turns": len(assistants),
        "tool_calls": sum(len(tool_calls_in(r)) for r in assistants),
        "tokens_input": totals["input"],
        "tokens_output": totals["output"],
        "tokens_cache_read": totals["cacheRead"],
        "tokens_cache_write": totals["cacheWrite"],
        "tokens_total": totals["totalTokens"],
        "compactions": sum(1 for r in records if r.get("type") == "compaction"),
        "model_elapsed_ms": None,
        "turns_before_first_edit": turns_before_first_edit,
        "stop_reasons": dict(Counter(r["message"].get("stopReason")
                                     for r in assistants
                                     if r["message"].get("stopReason"))),
        "provider_stamps": [r["message"].get("provider") for r in assistants],
        "model_stamps": [r["message"].get("model") for r in assistants],
    }


PARSERS = {"omp": parse_omp, "hax": parse_hax, "kit": parse_kit, "pi": parse_pi}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trial", required=True, type=pathlib.Path)
    ap.add_argument("--agent", required=True, choices=sorted(PARSERS))
    ap.add_argument("--provider", required=True,
                    help="the only provider id a valid trial may be served by")
    ap.add_argument("--model", required=True,
                    help="the only model id a valid trial may be served by")
    args = ap.parse_args()

    stats = PARSERS[args.agent](args.trial)

    meta = json.loads((args.trial / "meta.json").read_text()) \
        if (args.trial / "meta.json").is_file() else {}

    # kit's headless (`kit -p`) session log carries NO per-turn provider/model
    # stamp -- verified live: it persists neither message-level stamps nor a
    # model_change / system_prompt entry. So the per-turn-stamp contamination
    # check the other agents satisfy has nothing to read for kit.
    #
    # kit is configured (config/kit-bench.yml) with exactly ONE provider and NO
    # fallback, so -- unlike omp, which silently answered from a local ollama
    # when its provider broke -- an unreachable server makes kit hard-error
    # rather than reroute. Its routing is therefore verified SERVER-SIDE: if the
    # pinned sglang counters that trial.sh snapshots advanced by at least one
    # request per completed turn, the pinned server demonstrably served every
    # turn, and the pinned provider/model are attributed to each turn. Absent
    # that evidence (no meta.json, or too few server requests) the stamps stay
    # empty and the trial voids exactly like any other unproven routing.
    routing_verified_via = "session-stamps"
    if args.agent == "kit" and not any(stats["provider_stamps"]):
        server_requests = (meta.get("server_delta") or {}).get("requests", 0) or 0
        if stats["turns"] > 0 and server_requests >= stats["turns"]:
            stats["provider_stamps"] = [args.provider] * stats["turns"]
            stats["model_stamps"] = [args.model] * stats["turns"]
            routing_verified_via = "sglang-request-counter"

    providers = sorted({p for p in stats["provider_stamps"] if p})
    models = sorted({m for m in stats["model_stamps"] if m})
    fallback_count = sum(1 for p in stats["provider_stamps"]
                         if p not in (args.provider, None))
    wrong_model_count = sum(1 for m in stats["model_stamps"]
                            if m not in (args.model, None))

    void_reason = None
    if not stats["has_records"]:
        void_reason = "no session records; the agent produced no log"
    elif stats["turns"] == 0:
        void_reason = "session contains no completed model turns"
    elif fallback_count:
        void_reason = (f"{fallback_count} of {stats['turns']} model turns served by "
                       f"{[p for p in providers if p != args.provider]}, "
                       f"not {args.provider}")
    elif wrong_model_count:
        void_reason = (f"{wrong_model_count} of {stats['turns']} model turns served by "
                       f"{[m for m in models if m != args.model]}, "
                       f"not {args.model}")

    telemetry = {
        "agent": args.agent,
        "routing_verified_via": routing_verified_via,
        "turns": stats["turns"],
        "tool_calls": stats["tool_calls"],
        "tokens_input": stats["tokens_input"],
        "tokens_output": stats["tokens_output"],
        "tokens_cache_read": stats["tokens_cache_read"],
        "tokens_cache_write": stats["tokens_cache_write"],
        "tokens_total": stats["tokens_total"],
        "compactions": stats["compactions"],
        "model_elapsed_ms": stats["model_elapsed_ms"],
        "turns_before_first_edit": stats["turns_before_first_edit"],
        "stop_reasons": stats["stop_reasons"],
        "providers_seen": providers,
        "models_seen": models,
        "fallback_count": fallback_count,
        "void": void_reason is not None,
        "void_reason": void_reason,
        # Recorded here rather than in meta.json because it depends on the
        # contamination check: a contaminated trial did not complete on this
        # stack at all, however clean its exit code looks. `not void` closes a
        # vacuous-true loophole: a session with zero model turns has
        # fallback_count == 0 trivially, which must not read as "completed
        # cleanly".
        "completed_unassisted": (
            void_reason is None
            and fallback_count == 0
            and meta.get("agent_exit") == 0
            and meta.get("build_exit") == 0
            and meta.get("binary_present") is True
        ),
    }

    (args.trial / "telemetry.json").write_text(json.dumps(telemetry, indent=2) + "\n")
    print(json.dumps({k: telemetry[k] for k in
                      ("agent", "turns", "tool_calls", "tokens_total", "compactions",
                       "fallback_count", "void", "completed_unassisted")}))


if __name__ == "__main__":
    main()
