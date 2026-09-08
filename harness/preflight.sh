#!/usr/bin/env bash
# Verify the fixed controls (platform + chosen agent) against the live server
# and record the state of the world in results/<target>/<agent>/preflight.json.
# Run before every batch, not once ever: an unattended change partway through
# would silently confound everything after it.
#
# The MODEL is the variable and models are served one at a time, so preflight
# does NOT assert that every model in the set is live -- it records the set and
# the currently-served model. Per-model path/context verification happens in
# serve_model (lib.sh) at the start of each model's batch.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_agent "$AGENT"

mkdir -p "$RESULTS_ROOT"
OUT="$RESULTS_ROOT/preflight.json"

MODELS_JSON="$(curl -sS --max-time 15 "$SERVER_URL/v1/models")" \
  || die "cannot reach $SERVER_URL/v1/models (platform $TARGET)"

# The driver's own ollama daemon is the contamination hazard: an agent can
# silently fall back to it when its configured provider fails. Reachability is
# recorded and warned, not fatal -- telemetry.py voids any trial whose session
# records show a provider other than $PROVIDER_ID.
LOCAL_OLLAMA=false
if curl -sS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then
  LOCAL_OLLAMA=true
  log "WARNING: a local ollama daemon is running on the driver; a misrouted" \
      "agent can silently answer from it. Such trials are voided by telemetry."
fi

# A server already generating for someone else at batch start shares throughput
# and confounds the platform-constancy null-check. Recorded and warned, not
# fatal.
RUNNING_REQS="$(server_running_reqs)"
if [ "${RUNNING_REQS:-0}" -gt 0 ]; then
  log "WARNING: the server is already running $RUNNING_REQS request(s);" \
      "throughput taken now is shared with foreign load."
fi

read -r RTT_AVG RTT_MAX <<<"$(rtt_ms)"
AGENT_VERSION="$(agent_version)"

# Cross-check: is every model in the set at least listed by the platform right
# now? (Only informational -- sglang lists one, Lemonade may list several; the
# real per-model check is serve_model.)
MODEL_SET="$(jq -c '[.models[] | {id, served_model, model_path, context_length}]' "$MODELS_FILE")"

jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg driver "$(hostname)" \
  --arg target "$TARGET" --arg agent "$AGENT" --arg agent_version "$AGENT_VERSION" \
  --arg server_url "$SERVER_URL" \
  --argjson models "$MODELS_JSON" \
  --argjson model_set "$MODEL_SET" \
  --argjson local_ollama "$LOCAL_OLLAMA" \
  --argjson running_reqs "${RUNNING_REQS:-0}" \
  --arg go_version "$(go version)" --arg python_version "$(python3 --version)" \
  --arg requirements_sha256 "$(sha256sum "$REPO_ROOT/spec/REQUIREMENTS.md" | cut -d' ' -f1)" \
  --arg prompt_sha256 "$(sha256sum "$REPO_ROOT/spec/PROMPT.txt" | cut -d' ' -f1)" \
  --arg models_sha256 "$(sha256sum "$MODELS_FILE" | cut -d' ' -f1)" \
  --arg renderer_sha256 "$(sha256sum "$REPO_ROOT/harness/render_config.py" | cut -d' ' -f1)" \
  --argjson rtt_avg_ms "${RTT_AVG:-null}" --argjson rtt_max_ms "${RTT_MAX:-null}" '
  {
    timestamp: $ts, driver: $driver, target: $target,
    agent: $agent, agent_version: $agent_version,
    server_url: $server_url,
    served_now: [$models.data[]?.id],
    model_set: $model_set,
    models_in_set: ($model_set | length),
    models_listed_now: [$model_set[] | . as $m
                        | {id: $m.id, served_model: $m.served_model,
                           listed: ([$models.data[]?.id]
                                    | index($m.served_model) != null)}],
    local_ollama_on_driver: $local_ollama,
    server_busy_requests: $running_reqs,
    go_version: $go_version, python_version: $python_version,
    frozen: {
      requirements_sha256: $requirements_sha256,
      prompt_sha256: $prompt_sha256,
      models_sha256: $models_sha256,
      renderer_sha256: $renderer_sha256
    },
    rtt_avg_ms: $rtt_avg_ms, rtt_max_ms: $rtt_max_ms,
    ok: (($models.data | length) > 0)
  }' > "$OUT"

jq -r '"target         \(.target) (\(.server_url))",
       "agent          \(.agent) \(.agent_version)",
       "models in set  \(.models_in_set)",
       "served now     \(.served_now | join(", "))",
       "local ollama   \(.local_ollama_on_driver)",
       "busy requests  \(.server_busy_requests)",
       "go             \(.go_version)",
       "rtt avg ms     \(.rtt_avg_ms)",
       "OK             \(.ok)"' "$OUT"

jq -e '.ok' "$OUT" >/dev/null || die "platform not reachable / no models listed; see $OUT"
log "preflight OK -> $OUT"
