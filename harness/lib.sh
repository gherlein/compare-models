#!/usr/bin/env bash
# Shared constants and helpers. Sourced, never executed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# --- The two fixed controls: platform (TARGET) and agent (AGENT) --------------
#
# compare-models inverts compare-agents: the MODEL is the variable, the AGENT
# and the PLATFORM are held constant. TARGET selects the platform; AGENT selects
# the one coding agent that drives every model. Each target file
# (config/targets/$TARGET.sh) defines the platform constants -- SERVER_HOST,
# SERVER_URL, OPENAI_BASE_URL, PROVIDER_ID, CONFIG_DIR -- plus target_serve_model
# and the three server-introspection functions (server_model_info,
# server_running_reqs, server_counters), so the rest of the harness carries no
# platform-specific shapes.
TARGET="${TARGET:-dgx}"
TARGET_FILE="$REPO_ROOT/config/targets/$TARGET.sh"
[ -f "$TARGET_FILE" ] || die "unknown target: $TARGET (see config/targets/)"
# shellcheck source=/dev/null
source "$TARGET_FILE"
: "${SERVER_URL:?target $TARGET did not set SERVER_URL}"
: "${OPENAI_BASE_URL:?target $TARGET did not set OPENAI_BASE_URL}"
: "${PROVIDER_ID:?target $TARGET did not set PROVIDER_ID}"
: "${CONFIG_DIR:?target $TARGET did not set CONFIG_DIR}"

# The set of coding agents the harness can be pinned to. Exactly one is chosen
# per evaluation via AGENT; it is a CONTROL here, not the variable. omp is the
# default because its dialect engine can drive tool calling on models that do
# not natively support it, which widens the set of models a single fixed agent
# can fairly compare.
AGENTS="omp hax kit pi"
AGENT="${AGENT:-omp}"
case " $AGENTS " in
  *" $AGENT "*) ;;
  *) die "unknown agent: $AGENT (known: $AGENTS)" ;;
esac

# API key rendered agent configs present to the keyless bench servers. A dummy
# value; the servers ignore it but some clients require the field to be set.
API_KEY="${API_KEY:-bench-noauth}"

# The independent variable: the set of models to compare on this platform.
MODELS_FILE="$CONFIG_DIR/models.json"
[ -f "$MODELS_FILE" ] || die "no model set for target $TARGET: $MODELS_FILE missing"
jq -e '.models | type == "array" and length > 0' "$MODELS_FILE" >/dev/null 2>&1 \
  || die "$MODELS_FILE has no non-empty .models[] array"

# Space-separated model ids (the short labels) in file order.
model_ids() { jq -r '.models[].id' "$MODELS_FILE"; }

# One model entry as compact JSON, or non-zero if the id is unknown.
model_entry() {
  jq -e -c --arg id "$1" '.models[] | select(.id == $id)' "$MODELS_FILE"
}

# One scalar field of a model entry (jq path expression, e.g. .served_model).
model_attr() {
  local id="$1" path="$2"
  jq -r --arg id "$id" ".models[] | select(.id == \$id) | $path" "$MODELS_FILE"
}

# Results and workspaces are namespaced by platform AND agent, so switching
# either control never clobbers a prior evaluation's data. Trials within an
# evaluation are grouped by model in their ids (<model-id>-NN). results/ is
# gitignored; score.py honors TARGET and AGENT the same way.
RESULTS_ROOT="$REPO_ROOT/results/$TARGET/$AGENT"

# Agent workspaces live on LOCAL disk, not in the repo: the repo may sit on an
# NFS mount, and the agent builds and tests inside its workspace during the
# timed window -- NFS metadata latency there would inflate and add variance to
# the primary metric's explanatory timing. Archived copies land in results/
# after the clock stops.
WORKTREES_ROOT="${WORKTREES_ROOT:-$HOME/.cache/compare-models/worktrees/$TARGET/$AGENT}"

# Sources the adapter for the chosen agent, which must define agent_version and
# agent_run (contract documented in harness/agents/omp.sh).
load_agent() {
  local agent="$1"
  case " $AGENTS " in
    *" $agent "*) ;;
    *) die "unknown agent: $agent (known: $AGENTS)" ;;
  esac
  # shellcheck source=/dev/null
  source "$REPO_ROOT/harness/agents/$agent.sh"
}

# Is <served-model> listed by the platform's OpenAI /v1/models?
server_model_present() {
  local served="$1"
  curl -sS --max-time 15 "$SERVER_URL/v1/models" \
    | jq -e --arg m "$served" '[.data[]?.id] | index($m) != null' >/dev/null
}

# Make the model with the given short id the served model on this platform, then
# verify. The verification, not any swap, is the guarantee: target_serve_model is
# best effort (a no-op on one-model-per-instance sglang, a load request on
# Lemonade). On sglang a wrong live model dies here with an instruction to
# relaunch the server or run one model's batch at a time. Per-turn routing is
# additionally proven by telemetry.py.
serve_model() {
  local id="$1" served path live_path
  served="$(model_attr "$id" .served_model)"
  path="$(model_attr "$id" .model_path)"
  [ -n "$served" ] && [ "$served" != "null" ] || die "model '$id' has no served_model in $MODELS_FILE"

  target_serve_model "$served" "$path" || true

  server_model_present "$served" || die \
    "model '$served' (for id '$id') is not served at $SERVER_URL." \
    "On a one-model-per-instance backend (sglang), relaunch the server with" \
    "this model, or run a single model's batch with: make run-all MODEL=$id"

  live_path="$(server_model_info "$served" | jq -r '.model_path // empty')"
  if [ -n "$path" ] && [ "$path" != "null" ] && [ -n "$live_path" ] \
     && [ "$live_path" != "$path" ]; then
    die "served model_path '$live_path' != expected '$path' for model '$id';" \
        "the wrong checkpoint is live -- a control is violated"
  fi
  log "serve_model: '$id' -> $served ($live_path) live at $SERVER_URL"
}

rtt_ms() {
  # ping -q summary line splits on '/' as:
  #   1:"rtt min" 2:"avg" 3:"max" 4:"mdev = <min>" 5:<avg> 6:<max> 7:"<mdev> ms"
  ping -c 5 -q "$SERVER_HOST" 2>/dev/null \
    | awk -F'/' '/rtt/ {printf "%s %s", $5, $6}'
}

# Serialize inference load across the whole driver. The timing model assumes
# trials run one at a time (run-all.sh runs them strictly sequentially), and the
# per-trial server-counter deltas are only attributable because of that. A
# global, non-blocking lock makes a second concurrent trial fail fast with a
# clear message. Fd 9 stays open for the caller's lifetime and releases on exit,
# including on kill. Call once, early.
acquire_trial_lock() {
  local lock="$HOME/.cache/compare-models/trial.lock"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  flock -n 9 || die "another trial or smoke run holds $lock; trials must run" \
    "one at a time (the inference server is single-slot and the server-counter" \
    "deltas assume no concurrency). Wait for it to finish or stop it, then retry."
}

# SIGTERM then SIGKILL every descendant of a pid, depth-first so children die
# before their parents can be reaped and orphan the grandchildren. Used by
# trial.sh's interrupt trap.
kill_tree() {
  local sig="$1" pid="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$sig" "$child"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}
