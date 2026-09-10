# Findings: model comparison on a fixed agent and platform

Status: **preliminary (small N).** First data run of the compare-models harness.
See [VISION.md](../VISION.md) for the methodology and [README.md](../README.md)
for how to run it.

## Executive summary

Frozen coding task (`pngdec`, scored by a frozen 32-case suite), fixed agent
(**hax**), fixed platform (**Lemonade / llama.cpp on a Strix Halo box**); the
**model is the only variable** and **correctness is the primary metric**.

**Bottom line for this box: run Qwen3.8-27B (dense) with thinking OFF** — correct
and convergent, and far cheaper than thinking-on or the larger MoEs. Save
reasoning models for the design/planning phase, not the execution loop.

- **Winner: Qwen3.8-27B (dense)** — solved it perfectly and reliably (32/32, clean
  finish). The only consistently dependable model here.
- **Big MoE doesn't converge:** Qwen3-Next-80B-A3B thrashed to the 100-turn cap
  (11/32, ~9.85M tokens). No A3B MoE produced a clean finish — a *suggestive*
  dense-beats-sparse pattern, not yet proven.
- **Sharpest result — thinking on vs. off (Qwen3.8-27B, N=5):** with reasoning the
  only variable, **thinking OFF finished 3/5 and ON finished 0/5**, ~3x faster;
  thinking ON was marginally more correct when it produced code but **could not
  self-terminate** ("right but won't stop"). Thinking helps the single-pass answer,
  not the agentic loop.
- **Qwen3-Coder-30B excluded — a serving bug, not a coding verdict:** this
  llama.cpp build doesn't parse its `<function=…>` tool-call format, so no agent
  can drive it (confirmed by raw-API probe).
- **Every result is conditional on the agent:** omp couldn't drive these models
  (dialect vs. native tools, zero tool calls); hax could. Same models, opposite
  outcomes.
- **Method caveats:** small N (the thinking experiment is N=5; the rest N=1–2, and
  N=1 badly overstated the thinking effect's magnitude before N=5 corrected it);
  one task / agent / platform; some smoke-gate skips are harness-calibration
  artifacts, not model verdicts.

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
- **Thinking on vs. off (Qwen3.8-27B), N=5** — the sharpest result: with reasoning
  the only variable, **thinking OFF finished 3/5 vs thinking ON 0/5** and ran ~3x
  faster; thinking ON was marginally more correct when it produced code but
  couldn't self-terminate. See
  [the experiment](#experiment-thinking-on-vs-off-qwen38-27b).

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

## Experiment: thinking on vs. off (Qwen3.8-27B)

The sharpest result the harness has produced. Qwen3 is a hybrid-reasoning model,
so we ran the **same model, same quant, same sampling, same task, same agent** and
toggled *only* reasoning, via a per-model request passthrough
(`extra_body.chat_template_kwargs.enable_thinking`). Thinking is the only
variable. N=5 each.

| Qwen3.8-27B | anchor (median) | **finished rate** | completed | wall (median) | turns (median) | output tokens |
|---|---|---|---|---|---|---|
| **thinking OFF** | 0.94 (30/32) | **3/5 (60%)** | 3/5 | ~25 min | 85 | ~25K |
| **thinking ON** | 1.00 (32/32) | **0/5 (0%)** | 1/5 | 90 min (cap) | 20 | ~75K |

Per-trial spread (the reason N matters — single runs badly misrepresent either
config):

| variant | trial | anchor | finished | wall | turns | out tok |
|---|---|---|---|---|---|---|
| nothink | 01 | 30/32 | ✅ | 354 s | 14 | 6,963 |
| nothink | 02 | 20/32 | ❌ (turn cap) | 1531 s | 100 | 28,387 |
| nothink | 03 | 23/32 | ❌ (turn cap) | 2362 s | 100 | 37,554 |
| nothink | 04 | 32/32 | ✅ | 1578 s | 85 | 25,322 |
| nothink | 05 | 31/32 | ✅ | 662 s | 18 | 11,551 |
| think | 01 | 32/32 | ❌ (timeout) | 5400 s | 20 | 87,712 |
| think | 02 | 21/32 | ❌ (completed, sub-threshold) | 3244 s | 27 | 48,737 |
| think | 03 | 7/32 | ❌ (timeout, no binary) | 5400 s | 12 | 76,427 |
| think | 04 | 32/32 | ❌ (timeout) | 5400 s | 18 | 75,576 |
| think | 05 | 32/32 | ❌ (timeout) | 5400 s | 25 | 72,628 |

What holds up at N=5:

1. **Convergence — thinking OFF wins decisively.** nothink reached a clean,
   correct, self-terminated solution **3/5**; thinking ON did so **0/5**. The one
   think run that *stopped* did so at 21/32 (below threshold); the three think runs
   that hit 32/32 all **timed out** — correct code, never declared done. "Correct
   but can't stop" is the robust thinking-ON failure here, not a fluke.
2. **Raw correctness — thinking ON is marginally higher** *when it produces code*:
   median 32/32 vs 30/32. Thinking helps the answer; it wrecks the loop. (It also
   owns the worst single run — 7/32 with no binary.)
3. **Speed / tokens — thinking OFF far cheaper**: ~25 min vs the 90-min cap
   median; ~3x fewer output tokens.
4. **Both are high-variance.** nothink swings from a 6-min/14-turn clean 30/32 to a
   40-min/100-turn thrash; think from 32/32 to a 7/32 no-binary disaster. An N=1
   read (our first nothink run looked like a clean 6-minute 15x win) overstates
   the magnitude badly, though not the direction.

**Takeaway:** for an autonomous coding loop, **turn thinking off** — it is the only
setting that reaches a clean, correct, terminated result with any regularity
(60% vs 0%) and it is ~3x faster. Thinking's payoff lands on single-pass
correctness, not on driving a tool loop. This is the "deliberate single pass
(design / hard problems) vs. fast iteration (agentic execution)" split, measured.

Methodological note: `score.py` ranks thinking-ON above OFF because it sorts
anchor-first (1.00 > 0.94), yet OFF is plainly the better practical config
(finished 60% vs 0%). When completion diverges this sharply, the **`finished_rate`
column is the real story** — a candidate reason to weight finished-rate in the
primary sort.

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

- **Small N.** The base 27B has 2 trials and the 80B has 1 (single runs are
  indicative, not a ranking). The thinking on/off experiment is N=5 each — enough
  to trust its direction, though still modest for tight medians/IQR.
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
