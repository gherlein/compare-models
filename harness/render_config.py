#!/usr/bin/env python3
"""Render one agent's frozen configuration for one model under test.

compare-models varies the MODEL, and each model carries its own
vendor-recommended sampling and native context window (VISION.md: the model
bundle is not normalized). compare-agents could ship a static per-agent config
file because the model was a constant; here the served model id, its sampling,
and its context window change per model, so the config is rendered per model
instead. What stays frozen is (a) this renderer -- the single source of truth
for each agent's config shape and the rationale behind every control -- and (b)
config/<target>/models.json, which pins each model's sampling. Both are
SHA-256'd into every trial's metadata, and the rendered config is archived in
the trial output, so the exact config a trial ran under is always recoverable.

Rationale for the controls is carried over verbatim in spirit from
compare-agents; see the comments below. The platform base URL comes from the
target file; the model id / sampling / context come from the model entry.

Usage:
  render_config.py --agent omp --base-url http://dgx:8888/v1 --provider bench \\
      --model-file entry.json --api-key bench-noauth --out-dir <dir>

The model entry JSON shape (one element of models.json .models[]):
  {"id","served_model","model_path","context_length","max_tokens",
   "sampling":{"temperature","top_p","top_k","repetition_penalty"}}
"""

import argparse
import json
import pathlib


def _f(value: float) -> str:
    """Render a sampling number without a trailing .0 for integers."""
    if isinstance(value, bool):
        raise TypeError("sampling value must be numeric, not bool")
    if isinstance(value, int):
        return str(value)
    text = repr(float(value))
    return text


def render_omp(entry: dict, base_url: str, provider: str) -> dict[str, str]:
    served = entry["served_model"]
    ctx = int(entry["context_length"])
    s = entry.get("sampling", {})

    # models.yml: the provider definition omp seeds into a throwaway profile.
    # The discovery type MUST be exactly openai-models-list -- an invalid type
    # made omp reject the provider SILENTLY and fall back to the driver's local
    # ollama in shakedown. modelOverrides pins the context window so server-side
    # drift cannot change a control unnoticed; preflight cross-checks the live
    # value.
    models_yml = f"""\
# Rendered by harness/render_config.py for model '{entry['id']}' -- do not edit.
# Frozen provider definition for omp trials, seeded into the throwaway profile.
providers:
  {provider}:
    baseUrl: {base_url}
    api: openai-completions
    auth: none
    discovery:
      type: openai-models-list
    modelOverrides:
      "{served}":
        contextWindow: {ctx}
"""

    # omp-bench.yml: the frozen overlay. Sampling is the model's own
    # vendor-recommended values (NOT normalized across models -- VISION.md).
    # Every role routes to the one served model; fallback is off (a fallback
    # chain silently finishes a stalled turn on another provider and scores the
    # wrong model); cross-trial memory/learning is off so trial N cannot see
    # trial N-1; compaction and loop guards stay ON as part of the agent bundle.
    sampling_lines = [f"temperature: {_f(s['temperature'])}"]
    if "top_p" in s:
        sampling_lines.append(f"topP: {_f(s['top_p'])}")
    if "top_k" in s:
        sampling_lines.append(f"topK: {_f(s['top_k'])}")
    if "repetition_penalty" in s:
        sampling_lines.append(f"repetitionPenalty: {_f(s['repetition_penalty'])}")
    sampling_block = "\n".join(sampling_lines)

    omp_bench_yml = f"""\
# Rendered by harness/render_config.py for model '{entry['id']}' -- do not edit.
# Frozen omp overlay, loaded on every omp trial for this model.

# One server, one model, so every role routes to it.
modelRoles:
  default: {provider}/{served}
  smol: {provider}/{served}
  commit: {provider}/{served}
  plan: {provider}/{served}
  slow: {provider}/{served}
  vision: {provider}/{served}

# Sampling: this model's own vendor-recommended values (a per-model control,
# recorded in models.json and in each trial's metadata).
{sampling_block}

# Non-negotiable: no model fallback. A fallback chain finishes a stalled turn
# on a different provider and the trial silently scores the wrong stack.
retry:
  modelFallback: false
  enabled: true
  maxRetries: 10

# Raised from omp's ~300s defaults: a stream timeout is a wall-clock control,
# and a default sized for cloud APIs turns a long local prefill into a spurious
# failure.
providers:
  streamFirstEventTimeoutSeconds: 900
  streamIdleTimeoutSeconds: 900

# Cross-trial state off: each would let trial N see trial N-1's conclusions.
memories:
  enabled: false
autolearn:
  enabled: false
hindsight:
  mentalModelsEnabled: false
  mentalModelAutoSeed: false
contextPromotion:
  enabled: false
branchSummary:
  enabled: false
recap:
  enabled: false

# Model-switching machinery off: any of these would move work onto a different
# model mid-run, breaking the single-model-per-trial premise.
prewalk:
  enabled: false
advisor:
  enabled: false

# No outside information: the task must be solved from REQUIREMENTS.md.
exa:
  enabled: false

# Non-interactive runs cannot answer prompts.
tools:
  approvalMode: yolo

# Left ON: context overflow handling and loop guards are part of the agent
# bundle being held constant across models. Counts are recorded per trial.
compaction:
  enabled: true
  midTurnEnabled: true
model:
  loopGuard:
    enabled: true
  toolCallLoopGuard:
    enabled: true
"""
    return {"models.yml": models_yml, "omp-bench.yml": omp_bench_yml}


def render_hax(entry: dict, base_url: str, provider: str, api_key: str) -> dict[str, str]:
    served = entry["served_model"]
    ctx = int(entry["context_length"])
    s = entry.get("sampling", {})
    extra_body: dict = {"temperature": s["temperature"]}
    for src, dst in (("top_p", "top_p"), ("top_k", "top_k"),
                     ("repetition_penalty", "repetition_penalty")):
        if src in s:
            extra_body[dst] = s[src]
    # Optional per-model request passthrough, merged verbatim into the request
    # body via extra_body -- e.g. {"chat_template_kwargs": {"enable_thinking":
    # false}} to toggle Qwen3 thinking. Part of the model bundle, recorded in
    # models.json and the archived config.
    extra_body.update(entry.get("extra_body", {}))
    # hax config is pure JSON (no comments). It pins the bench provider to the
    # platform URL, the served model and its context window, disables the
    # models.dev catalog fetch (no network beyond inference), sets a 15m idle
    # timeout to match omp's 900s stream pins, and pins sampling via extra_body.
    config = {
        "provider": provider,
        "model": served,
        "context_limit": ctx,
        "catalog": {"url": "", "refresh": "0"},
        "http": {"idle_timeout": "15m"},
        "providers": {
            provider: {
                "display_name": provider,
                "base_url": base_url,
                "extra_body": extra_body,
            }
        },
    }
    return {"hax-config.json": json.dumps(config, indent=2) + "\n"}


def render_pi(entry: dict, base_url: str, provider: str, api_key: str) -> dict[str, str]:
    served = entry["served_model"]
    ctx = int(entry["context_length"])
    max_tokens = int(entry.get("max_tokens", 32768))
    s = entry.get("sampling", {})
    sampling_params: dict = {"temperature": s["temperature"]}
    for key in ("top_p", "top_k", "repetition_penalty"):
        if key in s:
            sampling_params[key] = s[key]
    # pi's models.json (pure JSON). A dummy apiKey makes the keyless server's
    # model selectable; compat flags follow pi's SGLang recommendation. pi
    # merges samplingParams verbatim into every request body, so pi is the one
    # agent that honors repetition_penalty too.
    config = {
        "providers": {
            provider: {
                "baseUrl": base_url,
                "api": "openai-completions",
                "apiKey": api_key,
                "compat": {"supportsDeveloperRole": False,
                           "supportsReasoningEffort": False},
                "models": [{
                    "id": served,
                    "name": served,
                    "contextWindow": ctx,
                    "maxTokens": max_tokens,
                    "samplingParams": sampling_params,
                }],
            }
        }
    }
    return {"pi-models.json": json.dumps(config, indent=2) + "\n"}


def render_kit(entry: dict, base_url: str, provider: str, api_key: str) -> dict[str, str]:
    served = entry["served_model"]
    ctx = int(entry["context_length"])
    max_tokens = int(entry.get("max_tokens", 32768))
    s = entry.get("sampling", {})

    # kit-bench.yml. The model string is "<provider>/<model>"; kit stamps both
    # halves onto every session entry and telemetry.py asserts them. CAVEAT: kit
    # exposes no repetition_penalty knob and no extra_body passthrough, so a
    # model whose recommendation includes repetition_penalty cannot have it
    # honored under kit -- an unavoidable, documented sampling asymmetry. The
    # other three sampling knobs are matched.
    sampling_lines = [f"temperature: {_f(s['temperature'])}"]
    if "top_p" in s:
        sampling_lines.append(f"top-p: {_f(s['top_p'])}")
    if "top_k" in s:
        sampling_lines.append(f"top-k: {_f(s['top_k'])}")
    rep_note = ""
    if "repetition_penalty" in s:
        rep_note = ("# NOTE: this model recommends repetition_penalty="
                    f"{_f(s['repetition_penalty'])}, which kit cannot set. "
                    "Left at kit's default (none).\n")
    sampling_block = "\n".join(sampling_lines)

    kit_bench_yml = f"""\
# Rendered by harness/render_config.py for model '{entry['id']}' -- do not edit.
# Frozen kit configuration, passed via `kit --config`.
model: {provider}/{served}

# Sampling: this model's own vendor-recommended values.
{rep_note}{sampling_block}
max-tokens: {max_tokens}

stream: false
"""

    # kit-bench-providers.json: seeded into kit's models.dev cache so it can
    # resolve <provider>/<model> and auto-route via @ai-sdk/openai-compatible.
    providers = {
        "providers": {
            provider: {
                "id": provider,
                "env": ["KIT_BENCH_KEY"],
                "npm": "@ai-sdk/openai-compatible",
                "api": base_url,
                "name": "Bench",
                "models": {
                    served: {
                        "id": served,
                        "name": served,
                        "family": "generic",
                        "attachment": False,
                        "reasoning": True,
                        "tool_call": True,
                        "temperature": True,
                        "cost": {"input": 0, "output": 0},
                        "limit": {"context": ctx, "output": max_tokens},
                    }
                },
            }
        }
    }
    return {"kit-bench.yml": kit_bench_yml,
            "kit-bench-providers.json": json.dumps(providers, indent=2) + "\n"}


RENDERERS = {"omp": render_omp, "hax": render_hax, "kit": render_kit, "pi": render_pi}


def render(agent: str, entry: dict, base_url: str, provider: str,
           api_key: str) -> dict[str, str]:
    if agent == "omp":
        return render_omp(entry, base_url, provider)
    return RENDERERS[agent](entry, base_url, provider, api_key)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", required=True, choices=sorted(RENDERERS))
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--provider", required=True)
    ap.add_argument("--api-key", default="bench-noauth")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--model-file", type=pathlib.Path,
                       help="JSON file holding the model entry")
    group.add_argument("--model-json", help="the model entry as a JSON string")
    ap.add_argument("--out-dir", required=True, type=pathlib.Path)
    args = ap.parse_args()

    entry = (json.loads(args.model_file.read_text()) if args.model_file
             else json.loads(args.model_json))
    if "sampling" not in entry or "temperature" not in entry["sampling"]:
        raise SystemExit(f"model entry '{entry.get('id')}' has no sampling.temperature")

    files = render(args.agent, entry, args.base_url, args.provider, args.api_key)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (args.out_dir / name).write_text(content)
    print(json.dumps({"agent": args.agent, "model": entry["id"],
                      "files": sorted(files)}))


if __name__ == "__main__":
    main()
