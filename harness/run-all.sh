#!/usr/bin/env bash
# Usage: run-all.sh [trials-per-model]
# Env: MODEL=<id> restricts the run to a single model's batch (required on a
# one-model-per-instance backend like sglang, where you relaunch the server
# between models).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TRIALS="${1:-1}"
LOG="$RESULTS_ROOT/run-all.log"
mkdir -p "$RESULTS_ROOT"

# Controls (platform + chosen agent + toolchain) are re-verified before the run.
bash "$REPO_ROOT/harness/preflight.sh"

# The model is the independent variable. The platform serves one model at a
# time, so models CANNOT be interleaved the way compare-agents interleaved
# agents on a single shared server; each model gets its own batch (VISION.md:
# "Per-model batches"). The platform-constancy null-check in score.py flags any
# cross-model throughput drift so the batching does not bias a model.
if [ -n "${MODEL:-}" ]; then
  model_entry "$MODEL" >/dev/null || die "unknown model id '$MODEL'"
  ids="$MODEL"
else
  ids="$(model_ids)"
fi

# A per-model failure must not abort the whole multi-model batch (VISION.md:
# transparent failure reporting, per-model batches). A model whose config-smoke
# fails -- the agent cannot drive it, or it timed out -- is recorded and skipped,
# and the run continues to the next model. `if ! ... | tee` disables set -e for
# the check and, with pipefail (set above), reflects the script's exit, not
# tee's. A trial failure is likewise logged without killing the remaining trials.
skipped=()
ran=()
for mid in $ids; do
  log "=== model batch: $mid ($TRIALS trials) ==="
  # Confirm this model is the served model AND prove the agent can drive it
  # (routing + at least one tool call) before burning trial time. serve_model
  # dies with an instruction if the model is not live (e.g. sglang serving a
  # different model); config-smoke dies if the agent cannot drive it.
  if ! bash "$REPO_ROOT/harness/config-smoke.sh" "$mid" 2>&1 | tee -a "$LOG"; then
    log "!!! model $mid: config-smoke FAILED (agent cannot drive this model, or" \
        "it timed out); recording and skipping its trials. See $LOG."
    skipped+=("$mid")
    continue
  fi
  for n in $(seq 1 "$TRIALS"); do
    log "=== trial $n on model $mid ==="
    if ! bash "$REPO_ROOT/harness/trial.sh" "$mid" "$n" 2>&1 | tee -a "$LOG"; then
      log "!!! model $mid trial $n FAILED (non-zero exit); continuing with the batch."
    fi
  done
  ran+=("$mid")
done

# Record which models produced trials and which were skipped, so a partial batch
# is legible without scrolling the log.
jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg target "$TARGET" \
  --arg agent "$AGENT" --argjson trials "$TRIALS" \
  --argjson ran "$(printf '%s\n' "${ran[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  --argjson skipped "$(printf '%s\n' "${skipped[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{timestamp:$ts, target:$target, agent:$agent, trials_per_model:$trials,
    models_ran:$ran, models_skipped:$skipped}' > "$RESULTS_ROOT/batch-status.json"

log "batch complete: ran [${ran[*]:-none}]; skipped [${skipped[*]:-none}]"
if [ "${#skipped[@]}" -gt 0 ]; then
  log "NOTE: $(( ${#skipped[@]} )) model(s) skipped -- the fixed agent could not drive them." \
      "A skipped model is an agent-fit failure, not a model-quality result."
fi
log "run 'make score' next"
