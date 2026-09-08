#!/usr/bin/env bash
# local platform -- this host's Lemonade Server (Strix Halo class box). Sourced
# by harness/lib.sh when TARGET=local. Same interface as dgx.sh; the shapes
# differ because Lemonade is a different stack.
#
# Lemonade (OpenAI-compatible, llama.cpp backend) at http://localhost:13305.
# Unlike sglang, Lemonade can hold several installed models and load one on
# demand, so target_serve_model can actually swap the served model here.
#
# The set of models to run through this platform lives in config/local/models.json.

SERVER_HOST="localhost"
# lib.sh's model check appends /v1/models to SERVER_URL, and Lemonade's OpenAI
# base is /api/v1 -- so SERVER_URL ends in /api and the append lands on
# /api/v1/models.
SERVER_URL="http://localhost:13305/api"
OPENAI_BASE_URL="$SERVER_URL/v1"
# Kept as "bench" so telemetry.py's provider assertion is identical for both
# platforms: the id is just the label rendered agent configs stamp.
PROVIDER_ID="bench"
CONFIG_DIR="$REPO_ROOT/config/local"

# Lemonade serves its Prometheus counters at /metrics (no /api prefix).
_LEMONADE_METRICS_URL="http://localhost:13305/metrics"

# Make the named model the served/loaded model, best effort. Lemonade exposes a
# load endpoint and also lazy-loads a model on the first chat request naming it,
# so this is advisory: serve_model() (lib.sh) still verifies the model is
# available afterward and per-turn routing is proven by telemetry.py. Failure
# here is non-fatal on purpose -- if the endpoint shape differs across Lemonade
# versions, the subsequent availability check is the real gate.
target_serve_model() {
  local served="$1"
  curl -sS --max-time 60 -X POST "$SERVER_URL/v1/load" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$served" '{model_name: $m}')" >/dev/null 2>&1 || true
  return 0
}

# Echo {model_path, context_length, server} as JSON for the named model, or
# return non-zero if the server is unreachable or does not list it. Lemonade's
# /api/v1/models entry carries both the checkpoint (model_path equivalent) and
# the context window.
server_model_info() {
  local served="$1" models
  models="$(curl -sS --max-time 15 "$SERVER_URL/v1/models")" || return 1
  jq -e --arg m "$served" '
    (.data[] | select(.id == $m)) as $e
    | ($e.max_context_window // $e.context_length) as $ctx
    | {
        model_path: $e.checkpoint,
        context_length: $ctx,
        server: {context_length: $ctx, recipe: $e.recipe,
                 quantization: null, kv_cache_dtype: null, version: null}
      }' <<<"$models"
}

# Models Lemonade is currently generating for. Health reports is_busy per loaded
# model; count the busy ones.
server_running_reqs() {
  curl -sS --max-time 15 "$SERVER_URL/v1/health" \
    | jq '[.all_models_loaded[]? | select(.is_busy == true)] | length' 2>/dev/null \
    || echo 0
}

# Server-side token/request counters for the CURRENTLY-served model. Lemonade's
# lemonade_model_*_total counters are labeled by model_name; sum across all of
# them for whatever model(s) served during the window (trials run strictly
# sequentially and one model is served at a time, so the delta is attributable).
# Field names match the dgx target's output: Lemonade "output_tokens" maps to
# sglang "generation_tokens".
server_counters() {
  curl -sS --max-time 15 "$_LEMONADE_METRICS_URL" | awk '
    $0 ~ /^lemonade_model_(prompt_tokens|output_tokens|requests|cache_tokens)_total\{/ {
      name=$1; sub(/\{.*/, "", name)
      sub(/^lemonade_model_/, "", name); sub(/_total$/, "", name)
      sums[name] += $2
    }
    END {
      printf "{\"prompt_tokens\":%.0f,\"generation_tokens\":%.0f,\"requests\":%.0f,\"cached_tokens\":%.0f}",
        sums["prompt_tokens"]+0, sums["output_tokens"]+0,
        sums["requests"]+0, sums["cache_tokens"]+0
    }'
}
