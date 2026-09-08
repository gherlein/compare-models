# Findings: model comparison on a fixed agent and platform

Status: **preliminary (small N).** First data run of the compare-models harness.
See [VISION.md](../VISION.md) for the methodology and [README.md](../README.md)
for how to run it.

## Headline

On this platform, with hax as the fixed driving agent, Qwen3 GGUF models were run
through the frozen `pngdec` coding task (implement a Go PNG chunk decoder that
passes a frozen 32-case suite the model never sees). Correctness (anchor pass
rate) is the primary metric.

- **`qwen3.8-27b` is the clear winner and the reliable model here** — 2/2 trials
  scored a perfect 32/32 and self-terminated cleanly.
- **`qwen3-next-80b-a3b` runs but does not converge** — it exhausted the agent's
  100-turn budget, burned ~9.85M tokens, and finished only 11/32.
- **Qwen3-Coder-30B-A3B was excluded** — this llama.cpp build does not parse its
  tool-call format, so no agent can drive it here (see
  [Excluded models](#excluded-models)). It is *not* a coding-ability result.

The most important cross-cutting result is an **agent-fit** one: the choice of
driving agent decided whether these models could be measured at all (see
[agent-fit](#agent-fit-omp-could-not-drive-these-models-hax-could)) — exactly the
conditionality the VISION flags as its central caveat.

## What was held constant (the controls)

| Control | Value |
|---|---|
| Platform | `local` — Lemonade Server (llama.cpp, ROCm build `llama-b10469`) on **helios**, an AMD Strix Halo box; OpenAI endpoint `http://localhost:13305/api` |
| Fixed agent | **hax** `v0.3.0-20-gcd9396d`, run non-interactively, isolated per-trial |
| Task / prompt / scorer | frozen `spec/` — `pngdec`, one kickoff prompt, the immutable 32-case anchor suite |
| Sampling | temperature 0.7, top-p 0.8, top-k 20, repetition-penalty 1.05 — each model's own vendor-recommended values (identical here because both are Qwen3 non-thinking) |
| Context window | 262144 (each model's native limit) |
| Time cap | 90 min (`MAX_TIME`) |
| Toolchain | go1.26.2 |
| Run dates | 2026-09-07 / 2026-09-08 |

## The models with data in this run

| id | served model | checkpoint / quant |
|---|---|---|
| `qwen3.8-27b` | Qwen3.8-27B-GGUF | `unsloth/…:Qwen3.8-27B-UD-Q4_K_XL.gguf` |
| `qwen3-next-80b-a3b` | Qwen3-Next-80B-A3B-Instruct-GGUF | `unsloth/…:Qwen3-Next-80B-A3B-Instruct-UD-Q4_K_XL.gguf` |

Six further Qwen3 models (8B/9B/14B/30B-A3B and the 3.5/3.6 35B-A3B pair) are
configured in `config/local/models.json` but have not been run yet — they are
future work, not part of this report.

## Results (agent = hax)

### Ranking (by anchor rate, then completion rate)

| rank | model | n | anchor rate | completed cleanly | finished | median time to finished |
|---|---|---|---|---|---|---|
| 1 | **qwen3.8-27b** | 2 | **1.00** (32/32) | 1.00 | 1.00 | ~64 min |
| 2 | qwen3-next-80b-a3b | 1 | 0.34 (11/32) | 0.00 | 0.00 | — |

*Finished = self-terminated cleanly AND anchor rate ≥ 0.80.*

### Per trial

| trial | anchor | finished | wall | turns | 1st-edit turn | tokens (total) | notes |
|---|---|---|---|---|---|---|---|
| qwen3.8-27b-01 | 32/32 | ✅ | 3703 s | 21 | 5 | 324,929 | clean |
| qwen3.8-27b-02 | 32/32 | ✅ | 3968 s | 19 | 3 | 347,724 | clean |
| qwen3-next-80b-a3b-01 | 11/32 | ❌ | 2430 s | **100** | 1 | **9,852,346** | hit hax's 100-turn cap (exit 1); did not converge |

### Task-integrity checks

- **Cross-matrix**: no model's binary passed the *other* model's self-written
  suite (`cross_pass_rate_excl_self = 0.00`); every trial's own suite caught the
  other binary (`catch_rate = 1.00`).
- **Over-strict suites**: both models' *self-written* tests fail the reference
  implementation (`suite_over_strict = true`) — they assert things
  `REQUIREMENTS.md` does not require. This does not affect the ranking:
  correctness is judged by the frozen anchor suite, and the 27B passed all 32
  anchor cases regardless.

## Interpretation

**qwen3.8-27b — the practical winner.** A plain dense 27B model solved the task
perfectly and reliably, twice, in ~20 turns each. On this hardware it is both the
most correct and the most dependable.

**qwen3-next-80b-a3b — capable but non-convergent.** The largest model reached
only 11/32 and never self-terminated: it ran the agent's full 100-turn budget and
consumed ~9.85M tokens (two orders of magnitude more than the 27B) without
settling on a correct solution. On this stack it is impractical for autonomous
coding — it thrashes rather than converges. Whether that is the model, the quant,
or an interaction with hax's loop is not separable from this single run.

## Excluded models

**Qwen3-Coder-30B-A3B-Instruct (both Q4_K_M and UD-Q4_K_XL) — removed.** The model
emits tool calls in Qwen3-Coder's `<function=…>` XML format, and this llama.cpp
build does **not** parse that into an OpenAI `tool_calls` field. Confirmed with a
raw `POST /v1/chat/completions` probe (explicit `tools` array, `tool_choice:
auto`): the response comes back as plain text reciting a `<function=…>` template,
`tool_calls: null`. Because the server never emits a tool call, no agent (hax or
omp) can drive it, and it produced no valid trial. This is a **serving-side
tool-format limitation, not a verdict on the model's coding ability** — which
remains unmeasured here. It has been dropped from the model set and deleted from
the box.

## Agent-fit: omp could not drive these models; hax could

An earlier run used **omp** (`18.0.3`) as the fixed agent and failed structurally:
omp auto-selected its **text dialect** instead of the platform's **native tools
API**, so it sent no `tools` and the models free-formed — completing turns with
**zero tool calls** (never even reading `REQUIREMENTS.md`), and its routing smoke
timed out. A direct `/v1/chat/completions` probe with a `tools` array proved the
platform itself does native tool calling; hax, which is native-tools-only, drove
the 27B and 80B correctly (verified by the tool-call smoke gate).

**Consequence:** the ranking is conditional on the agent. Every number here is
"this model, as driven by *hax*, on *this* platform" — the VISION's central caveat
made concrete.

## Limitations

- **Small N.** The 27B has 2 trials; the 80B has 1. Single runs are indicative,
  not a ranking; no medians/IQR are meaningful yet.
- **One agent, one platform.** Results do not generalize to other agents (see
  above) or to the dgx/sglang platform, which was not run.
- **The 80B's non-convergence** is entangled with hax's 100-turn cap; a larger cap
  or a different agent might change it.

## Reproducibility

```sh
# platform = local (Lemonade on helios), agent = hax
make preflight    TARGET=local AGENT=hax
make run-all      TARGET=local AGENT=hax TRIALS=5     # per-model batches
make score        TARGET=local AGENT=hax             # writes results/local/hax/scores.md
```

Every trial records the agent version, served model + checkpoint, sampling, the
rendered agent config, SHA-256 of the frozen task/prompt/model-set/renderer, and
the full session transcript under `results/local/hax/trials/<id>/`. The frozen
task and 32-case anchor suite are byte-identical to compare-agents and
compare-platform, so results on this task are comparable across the lineage.

## Recommended next steps

1. **Run the rest of the set** — the six configured-but-unrun Qwen3 models
   (8B/9B/14B/30B-A3B and the 3.5/3.6 35B-A3B pair). The 35B-A3B pair is the most
   interesting: do smaller A3B MoEs also fail to converge like the 80B did, or is
   that 80B-specific?
2. **Solidify the ranking** — take the models that complete to N=5 for
   trustworthy medians and a real reliability rate on the 80B's non-convergence.
3. **Run a second lens** — repeat under a different fixed agent and `make compare`
   to quantify how much the ranking is agent-conditional.
