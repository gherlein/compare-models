#!/usr/bin/env bash
# Prove, for the chosen agent and each model under test, that the agent can
# actually DRIVE the model before spending full-length trials: run a one-tool
# prompt through the real adapter path, then assert the session records (a) stamp
# exactly the pinned provider and the model's served id and (b) contain at least
# one tool call. The tool-call assertion is load-bearing: an agent that reaches
# the model but never emits a parseable tool call (observed: omp auto-selecting
# its text dialect instead of native tools over Lemonade, producing zero tool
# calls and never even reading the task) would otherwise pass a routing-only
# smoke and then waste a full trial producing nothing.
#
# Usage: config-smoke.sh [model-id]   (default: every model in the set)
# On a one-model-per-instance backend (sglang) pass the currently-served model
# id, since serve_model dies on a model that is not live.
# SMOKE_MAX_TIME caps each smoke agent run (default 8m); the model load done by
# serve_model happens before the cap, so this covers only the one-tool exchange.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_agent "$AGENT"
acquire_trial_lock

SMOKE_MAX_TIME="${SMOKE_MAX_TIME:-8m}"

SMOKE_ROOT="$RESULTS_ROOT/config-smoke"
PROMPT_FILE="$SMOKE_ROOT/prompt.txt"
rm -rf "$SMOKE_ROOT"
mkdir -p "$SMOKE_ROOT"
printf "Run the shell command 'echo smoke-ok' and tell me its output.\n" > "$PROMPT_FILE"

FILTER="${1:-}"
if [ -n "$FILTER" ]; then
  model_entry "$FILTER" >/dev/null || die "unknown model id '$FILTER'"
  ids="$FILTER"
else
  ids="$(model_ids)"
fi

for MODEL_ID in $ids; do
  ENTRY="$(model_entry "$MODEL_ID")"
  MODEL_SERVED="$(jq -r '.served_model' <<<"$ENTRY")"
  export MODEL_ID MODEL_SERVED

  serve_model "$MODEL_ID"

  out="$SMOKE_ROOT/$MODEL_ID"
  tree="$out/ws"
  mkdir -p "$out" "$tree"
  MODEL_ENTRY_FILE="$out/model.json"
  printf '%s\n' "$ENTRY" > "$MODEL_ENTRY_FILE"
  export MODEL_ENTRY_FILE

  log "config-smoke: agent=$AGENT model=$MODEL_ID ($MODEL_SERVED)"
  # Snapshot the pinned server's counters around the run and write a minimal
  # meta.json with the delta, so kit's server-counter routing proof has data
  # (kit's headless log carries no per-turn stamps; see telemetry.py).
  server_before="$(server_counters)"
  set +e
  agent_run "$tree" "$out" "smoke-$MODEL_ID" "$SMOKE_MAX_TIME" "$PROMPT_FILE"
  exit_code=$?
  set -e
  [ "$exit_code" -eq 0 ] || die "$AGENT smoke run for $MODEL_ID exited $exit_code; see $out/agent.err"
  server_after="$(server_counters)"
  jq -n --argjson b "$server_before" --argjson a "$server_after" \
    '{server_delta: {
        prompt_tokens: ($a.prompt_tokens - $b.prompt_tokens),
        generation_tokens: ($a.generation_tokens - $b.generation_tokens),
        requests: ($a.requests - $b.requests),
        cached_tokens: ($a.cached_tokens - $b.cached_tokens)
      }}' > "$out/meta.json"

  python3 "$REPO_ROOT/harness/telemetry.py" --trial "$out" --agent "$AGENT" \
    --provider "$PROVIDER_ID" --model "$MODEL_SERVED" > /dev/null

  jq -e --arg p "$PROVIDER_ID" --arg m "$MODEL_SERVED" '
    (.void | not)
    and (.turns >= 1)
    and (.tool_calls >= 1)
    and (.providers_seen == [$p])
    and (.models_seen == [$m])' "$out/telemetry.json" >/dev/null \
    || die "$AGENT cannot drive $MODEL_ID: smoke failed routing/tool-call assertions" \
           "(tool_calls=$(jq -c .tool_calls "$out/telemetry.json"), " \
           "providers=$(jq -c .providers_seen "$out/telemetry.json"), " \
           "models=$(jq -c .models_seen "$out/telemetry.json")); see $out/telemetry.json and $out/agent.out"
  log "config-smoke: $MODEL_ID OK (tool_calls=$(jq -c .tool_calls "$out/telemetry.json"), providers=$(jq -c .providers_seen "$out/telemetry.json"))"
done

log "config-smoke OK for agent=$AGENT models: $(echo "$ids" | tr '\n' ' ')"
