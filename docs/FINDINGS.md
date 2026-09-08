# Findings: model comparison on a fixed agent and platform

Status: **preliminary (small N; one blocked model).** First data run of the
compare-models harness. See [VISION.md](../VISION.md) for the methodology and
[README.md](../README.md) for how to run it.

## Headline

On this platform, with hax as the fixed driving agent, a **set of three Qwen3
GGUF models** was run through the frozen `pngdec` coding task (implement a Go PNG
chunk decoder that passes a frozen 32-case suite the model never sees).
Correctness (anchor pass rate) is the primary metric.

- **`qwen3.8-27b` is the clear winner and the only reliable model here** — 2/2
  trials scored a perfect 32/32 and self-terminated cleanly.
- **`qwen3-next-80b-a3b` runs but does not converge** — it exhausted the agent's
  100-turn budget, burned ~9.85M tokens, and finished only 11/32.
- **`qwen3-coder-30b-a3b` could not be served reliably** — it wedges the
  inference server reproducibly (even after a clean restart) and produced no
  valid trial. **This is a serving/platform failure, not a verdict on the
  model's coding ability**, which remains unmeasured here.

The most important cross-cutting result is an **agent-fit** one: the choice of
driving agent decided whether *any* of these models could be measured at all
(see [omp vs hax](#agent-fit-omp-could-not-drive-these-models-hax-could)). That
is exactly the conditionality the VISION flags as its central caveat.

## What was held constant (the controls)

| Control | Value |
|---|---|
| Platform | `local` — Lemonade Server (llama.cpp, ROCm build `llama-b10469`) on **helios**, an AMD Strix Halo box; OpenAI endpoint `http://localhost:13305/api` |
| Fixed agent | **hax** `v0.3.0-20-gcd9396d`, run non-interactively, isolated per-trial (an omp run is discussed separately below) |
| Task / prompt / scorer | frozen `spec/` — `pngdec`, one kickoff prompt, the immutable 32-case anchor suite |
| Sampling | temperature 0.7, top-p 0.8, top-k 20, repetition-penalty 1.05 — each model's own vendor-recommended values (identical here because all three are Qwen3 non-thinking) |
| Context window | 262144 (each model's native limit) |
| Time cap | 90 min (`MAX_TIME`), except the post-restart Coder retry at 20 min |
| Toolchain | go1.26.2 |
| Run date | 2026-09-07 |

## The variable: the model set

| id | served model | checkpoint / quant |
|---|---|---|
| `qwen3-coder-30b-a3b` | Qwen3-Coder-30B-A3B-Instruct-GGUF | `unsloth/…:Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` |
| `qwen3.8-27b` | Qwen3.8-27B-GGUF | `unsloth/…:Qwen3.8-27B-UD-Q4_K_XL.gguf` |
| `qwen3-next-80b-a3b` | Qwen3-Next-80B-A3B-Instruct-GGUF | `unsloth/…:Qwen3-Next-80B-A3B-Instruct-UD-Q4_K_XL.gguf` |

## Results (agent = hax)

### Ranking (by anchor rate, then completion rate)

| rank | model | n | anchor rate | completed cleanly | finished | median time to finished |
|---|---|---|---|---|---|---|
| 1 | **qwen3.8-27b** | 2 | **1.00** (32/32) | 1.00 | 1.00 | ~64 min |
| 2 | qwen3-next-80b-a3b | 1 | 0.34 (11/32) | 0.00 | 0.00 | — |
| 3 | qwen3-coder-30b-a3b | 1 | 0.22 (7/32) | 0.00 | 0.00 | — |

*Finished = self-terminated cleanly AND anchor rate ≥ 0.80.*

### Per trial

| trial | anchor | finished | wall | turns | 1st-edit turn | tokens (total) | notes |
|---|---|---|---|---|---|---|---|
| qwen3.8-27b-01 | 32/32 | ✅ | 3703 s | 21 | 5 | 324,929 | clean |
| qwen3.8-27b-02 | 32/32 | ✅ | 3968 s | 19 | 3 | 347,724 | clean |
| qwen3-next-80b-a3b-01 | 11/32 | ❌ | 2430 s | **100** | 1 | **9,852,346** | hit hax's 100-turn cap (exit 1); did not converge |
| qwen3-coder-30b-a3b-01 | 7/32 | ❌ | 330 s | 33 | 1 | 406,923 | partial binary; build failed; did not finish |
| qwen3-coder-30b-a3b-02 | — | — | 1200 s | 0 | — | 0 | **voided** — server wedged, no completed turns (post-restart retry) |

### Task-integrity checks

- **Cross-matrix**: no model's binary passed any *other* model's self-written
  suite (`cross_pass_rate_excl_self = 0.00` across the board), and every trial's
  own suite caught at least one other binary (`catch_rate = 1.00`).
- **Over-strict suites**: both the 27B's and the 80B's *self-written* tests fail
  the reference implementation (`suite_over_strict = true`) — i.e., they assert
  things `REQUIREMENTS.md` does not require. This does **not** affect the ranking:
  correctness is judged by the frozen anchor suite, and the 27B passed all 32
  anchor cases regardless of its own over-strict tests.

## Interpretation

**qwen3.8-27b — the practical winner.** A plain dense 27B model solved the task
perfectly and reliably, twice, in ~20 turns each, starting to edit after a few
turns of planning. On this hardware it is both the most correct and the most
dependable of the three.

**qwen3-next-80b-a3b — capable but non-convergent.** The largest model reached
only 11/32 and never self-terminated: it ran the agent's full 100-turn budget
and consumed ~9.85M tokens (two orders of magnitude more than the 27B) without
settling on a correct solution. On this stack it is impractical for autonomous
coding — it thrashes rather than converges. Whether that is the model, the
quant, or an interaction with hax's loop is not separable from this single run.

**qwen3-coder-30b-a3b — blocked by a serving failure.** The coding specialist
never produced a valid trial. It intermittently free-forms a large response
instead of emitting a tool call, and the llama.cpp generation then **stalls with
no forward progress** (observed live: server `busy`, output-token counter frozen
at 16,753). This reproduced **after a clean `systemctl restart lemond.service`**:
the retry ran 20 minutes with **zero completed turns** and was correctly voided.
Its 7/32 first trial is a truncated-run artifact, not a measure of coding
ability. **We therefore cannot say how good a coder this model is on this
platform — only that it cannot be served reliably here.** For a deployment
decision on this hardware, that is itself the relevant result: the specialist you
would reach for first is the one you cannot currently run.

## Agent-fit: omp could not drive these models; hax could

An earlier run used **omp** (`18.0.3`) as the fixed agent and failed structurally:

- Against the Coder, omp completed **1 turn with 0 tool calls**. It never called
  `read`, so it never saw `REQUIREMENTS.md`, and instead hallucinated a task by
  regurgitating omp's *own* edit-tool schema (`-path` / `-content` / `-i` intent),
  dumping code into markdown. No binary; anchor 0.
- Against the 27B, omp's routing smoke **timed out** and aborted the batch.

A direct probe proved the stack itself is fine: `POST /v1/chat/completions` with a
`tools` array returns `finish_reason: tool_calls` and a well-formed call. The
problem is that omp, over this OpenAI-compatible endpoint, auto-selected its
**text dialect** instead of the **native tools API**, so it sent no `tools` and
the models free-formed. hax, which is native-tools-only, drove the 27B and 80B
correctly (verified by the tool-call smoke gate).

**Consequence:** the model ranking is conditional on the agent. Under omp, *all
three* models were unmeasurable here; under hax, two of three were. This is the
VISION's central caveat made concrete — every number in this report is "this
model, as driven by *hax*, on *this* platform."

## Limitations

- **Small N.** The 27B has 2 trials; the others have 1 valid trial or none.
  Single runs are indicative, not a ranking. No medians/IQR are meaningful yet.
- **One agent, one platform.** Results do not generalize to other agents (see
  above) or to the dgx/sglang platform, which was not run.
- **The Coder is unmeasured**, not "worst" — do not read its 7/32 as a coding
  score.
- **The 80B's non-convergence** is entangled with hax's 100-turn cap; a larger
  cap or a different agent might change it.
- Sampling coincided across models (all Qwen3 non-thinking); a heterogeneous set
  would exercise the per-model-sampling machinery differently.

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

1. **Rescue the Coder (serving-side).** Only the `Q4_K_M` build is installed;
   every model that *works* here is `UD-Q4_K_XL`. Pull a `Q4_K_XL` Coder GGUF and
   retest — the likeliest fix. Also inspect the per-model `llama-server` spawn
   flags (`sudo journalctl -u lemond`) for speculative-decoding/draft flags that
   wedge MoE models.
2. **Solidify the ranking** — take 27B and 80B to N=5 for trustworthy medians
   and a real reliability rate on the 80B's non-convergence.
3. **Run the second lens** — repeat under a different fixed agent and
   `make compare` to quantify how much the ranking is agent-conditional.
