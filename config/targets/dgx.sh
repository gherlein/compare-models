#!/usr/bin/env bash
# dgx platform -- the pinned NVIDIA stack. Sourced by harness/lib.sh when
# TARGET=dgx (the default).
#
# In compare-models the model is the VARIABLE, so this file no longer pins a
# single MODEL the way compare-agents' target files did. It pins the PLATFORM
# (a control): the server endpoint, the OpenAI base URL every rendered agent
# config points at, the provider id every config registers, and the three
# server-introspection functions the harness calls. The set of models to run
# through this platform lives in config/dgx/models.json.
#
# sglang on ASUS Ascent GX10 (NVIDIA GB10), OpenAI-compatible at http://dgx:8888.

SERVER_HOST="dgx"
SERVER_URL="http://dgx:8888"
# The OpenAI base every rendered agent config uses. lib.sh's model checks append
# /v1/models to SERVER_URL; agents talk to $SERVER_URL/v1.
OPENAI_BASE_URL="$SERVER_URL/v1"
# The provider id every rendered agent config registers for this platform.
# Session records must stamp exactly this id on every model turn; telemetry.py
# asserts it. Kept identical across platforms so the assertion is uniform.
PROVIDER_ID="bench"
CONFIG_DIR="$REPO_ROOT/config/dgx"

# Make the named model the served model on this platform, best effort.
#
# sglang serves ONE model per server instance -- there is no online model swap.
# So this is a no-op: the harness's serve_model() wrapper (lib.sh) verifies the
# requested model is the one currently live and, if not, dies with an
# instruction to relaunch sglang with that model (or to run a single model's
# batch with `make run-all MODEL=<id>`). The verification, not a swap, is what
# guarantees the right model; per-turn routing is additionally proven by
# telemetry.py's contamination check.
target_serve_model() {
  return 0
}

# Echo {model_path, context_length, server} as JSON for the currently-served
# model, or return non-zero if the server is unreachable. sglang serves a single
# model, so the argument (the expected served-model id) is accepted for a uniform
# signature but not used to select among models. sglang exposes /get_model_info
# and /get_server_info.
server_model_info() {
  local mi si
  mi="$(curl -sS --max-time 15 "$SERVER_URL/get_model_info")"   || return 1
  si="$(curl -sS --max-time 15 "$SERVER_URL/get_server_info")"  || return 1
  jq -n --argjson mi "$mi" --argjson si "$si" '{
    model_path: $mi.model_path,
    context_length: $si.context_length,
    server: ($si | {context_length, kv_cache_dtype, quantization,
                    max_running_requests, chunked_prefill_size,
                    mem_fraction_static, version: (.version // null)})
  }'
}

# Number of requests the server is currently generating (0 when idle).
server_running_reqs() {
  curl -sS --max-time 15 "$SERVER_URL/metrics" \
    | awk '/^sglang:num_running_reqs\{/ {sum += $2} END {printf "%.0f", sum+0}'
}

# Server-side token/request counters, summed across label sets. Snapshotted
# before and after each agent run; the deltas are an independent cross-check of
# the tokens the agent's own session log reports, and -- for kit, whose log
# carries no per-turn stamps -- the evidence telemetry.py uses to prove routing.
server_counters() {
  curl -sS --max-time 15 "$SERVER_URL/metrics" | awk '
    /^sglang:(prompt_tokens_total|generation_tokens_total|num_requests_total|cached_tokens_total)\{/ {
      name=$1; sub(/\{.*/, "", name); sub(/^sglang:/, "", name); sums[name] += $2
    }
    END {
      printf "{\"prompt_tokens\":%.0f,\"generation_tokens\":%.0f,\"requests\":%.0f,\"cached_tokens\":%.0f}",
        sums["prompt_tokens_total"]+0, sums["generation_tokens_total"]+0,
        sums["num_requests_total"]+0, sums["cached_tokens_total"]+0
    }'
}
