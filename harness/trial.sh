#!/usr/bin/env bash
# One trial. Usage: trial.sh <model-id> <trial-number>
# The agent and platform are fixed controls (AGENT / TARGET from the env, via
# lib.sh); the model is the variable and is named by <model-id> (a key in
# config/$TARGET/models.json).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

MODEL_ID="${1:?usage: trial.sh <model-id> <n>}"
NUM="${2:?usage: trial.sh <model-id> <n>}"
load_agent "$AGENT"

# Resolve the model under test from the frozen set.
ENTRY="$(model_entry "$MODEL_ID")" \
  || die "unknown model id '$MODEL_ID' (known: $(model_ids | tr '\n' ' '))"
MODEL_SERVED="$(jq -r '.served_model' <<<"$ENTRY")"
MODEL_PATH_EXPECTED="$(jq -r '.model_path' <<<"$ENTRY")"
export MODEL_ID MODEL_SERVED

# Refuse to run concurrently with another trial (single-slot server; the
# server-counter deltas assume no concurrency). Held for this script's lifetime.
acquire_trial_lock

on_interrupt() {
  trap - INT TERM
  log "${TRIAL_ID:-trial}: interrupted; stopping agent"
  if [ -n "${agent_pid:-}" ]; then
    kill_tree TERM "$agent_pid"
    sleep 2
    kill_tree KILL "$agent_pid"
  fi
  exit 130
}
trap on_interrupt INT TERM

# Generous on purpose: a tight cap strands correct code and corrupts
# completion-rate data. Recorded per trial so runs at different caps are never
# compared blind.
MAX_TIME="${MAX_TIME:-90m}"
TRIAL_ID="$(printf '%s-%02d' "$MODEL_ID" "$NUM")"
OUT="$RESULTS_ROOT/trials/$TRIAL_ID"
TREE="$WORKTREES_ROOT/$TRIAL_ID"

# Require valid JSON, not mere existence: a failed jq leaves a 0-byte meta.json
# that would otherwise pass this check forever and silently lose the trial on
# every future resume.
if [ -s "$OUT/meta.json" ] && jq -e . "$OUT/meta.json" >/dev/null 2>&1; then
  log "$TRIAL_ID already complete, skipping"
  exit 0
fi

set -e
# $TREE is always wiped -- a fresh agent workspace every attempt. $OUT too: a
# prior interrupted attempt can leave a stale tree/ from a different build, and
# a retry whose own build fails would otherwise silently score leftovers.
rm -rf "$OUT" "$TREE"
mkdir -p "$OUT" "$TREE"

# The model entry is archived and fed to the adapter's render_config step.
MODEL_ENTRY_FILE="$OUT/model.json"
printf '%s\n' "$ENTRY" > "$MODEL_ENTRY_FILE"
export MODEL_ENTRY_FILE

# A fresh git init rather than a worktree of this repo: a worktree would put
# spec/anchor and spec/reference inside the agent's workspace.
cp "$REPO_ROOT/spec/REQUIREMENTS.md" "$TREE/REQUIREMENTS.md"
git -C "$TREE" init -q
git -C "$TREE" add REQUIREMENTS.md
git -C "$TREE" -c user.name=bench -c user.email=bench@localhost \
  commit -qm "requirements"

# Verify the model under test is the one the platform is serving (a control).
serve_model "$MODEL_ID"
MODEL_PATH="$(server_model_info "$MODEL_SERVED" | jq -r '.model_path // empty')"
read -r RTT_AVG _ <<<"$(rtt_ms)"
AGENT_VERSION="$(agent_version)"
SERVER_BEFORE="$(server_counters)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_NS="$(date +%s%N)"

log "$TRIAL_ID: running agent=$AGENT model=$MODEL_ID ($MODEL_SERVED) cap $MAX_TIME"
set +e
# Backgrounded so on_interrupt can reach the agent's process tree via agent_pid
# while `wait` blocks. 9>&- closes the lock fd in the agent subprocess so it can
# never hold the lock; only this script does, releasing on exit.
agent_run "$TREE" "$OUT" "$TRIAL_ID" "$MAX_TIME" "$REPO_ROOT/spec/PROMPT.txt" 9>&- &
agent_pid=$!
wait "$agent_pid"
AGENT_EXIT=$?
agent_pid=""
set -e

END_NS="$(date +%s%N)"
ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SERVER_AFTER="$(server_counters)"
WALL_SECONDS="$(awk -v a="$START_NS" -v b="$END_NS" 'BEGIN{printf "%.3f", (b-a)/1e9}')"
log "$TRIAL_ID: agent exited $AGENT_EXIT after ${WALL_SECONDS}s"

# The clock stops before the build: build and test time is the driver's cost,
# not the agent's, and including it would add driver noise.
set +e
make -C "$TREE" build > "$OUT/build.log" 2>&1
BUILD_EXIT=$?
make -C "$TREE" test > "$OUT/test.log" 2>&1
TEST_EXIT=$?
set -e

BINARY_PRESENT=false
if [ -x "$TREE/pngdec" ]; then
  cp "$TREE/pngdec" "$OUT/pngdec"
  BINARY_PRESENT=true
else
  log "$TRIAL_ID: WARNING no executable at $TREE/pngdec; anchor and cross scores will be zero"
fi

# -count=1 defeats Go's test cache, which would otherwise reuse one binary's
# results for the next binary at the same test source.
set +e
PNGDEC_BIN="$OUT/pngdec" go test -C "$REPO_ROOT/spec/anchor" -count=1 -json ./... \
  > "$OUT/anchor.json" 2>&1
set -e

rsync -a --exclude '.git/' "$TREE/" "$OUT/tree/"

jq -n \
  --arg trial_id "$TRIAL_ID" --arg agent "$AGENT" \
  --arg agent_version "$AGENT_VERSION" --arg driver "$(hostname)" \
  --arg target "$TARGET" \
  --arg model_id "$MODEL_ID" --arg model "$MODEL_SERVED" \
  --arg model_path "$MODEL_PATH" --arg model_path_expected "$MODEL_PATH_EXPECTED" \
  --argjson model_entry "$ENTRY" \
  --arg server_url "$SERVER_URL" \
  --arg requirements_sha256 "$(sha256sum "$REPO_ROOT/spec/REQUIREMENTS.md" | cut -d' ' -f1)" \
  --arg prompt_sha256 "$(sha256sum "$REPO_ROOT/spec/PROMPT.txt" | cut -d' ' -f1)" \
  --arg models_sha256 "$(sha256sum "$MODELS_FILE" | cut -d' ' -f1)" \
  --arg renderer_sha256 "$(sha256sum "$REPO_ROOT/harness/render_config.py" | cut -d' ' -f1)" \
  --arg started_at "$STARTED_AT" --arg ended_at "$ENDED_AT" \
  --arg max_time "$MAX_TIME" \
  --argjson wall_seconds "$WALL_SECONDS" \
  --argjson agent_exit "$AGENT_EXIT" --argjson build_exit "$BUILD_EXIT" \
  --argjson test_exit "$TEST_EXIT" --argjson binary_present "$BINARY_PRESENT" \
  --argjson rtt_avg_ms "${RTT_AVG:-null}" \
  --argjson server_before "$SERVER_BEFORE" --argjson server_after "$SERVER_AFTER" \
  '$ARGS.named
   | .server_delta = {
       prompt_tokens: (.server_after.prompt_tokens - .server_before.prompt_tokens),
       generation_tokens: (.server_after.generation_tokens - .server_before.generation_tokens),
       requests: (.server_after.requests - .server_before.requests),
       cached_tokens: (.server_after.cached_tokens - .server_before.cached_tokens)
     }' > "$OUT/meta.json.tmp"
mv "$OUT/meta.json.tmp" "$OUT/meta.json"

# After meta.json, not before: completed_unassisted is derived from agent_exit,
# build_exit and binary_present. The contamination check asserts the SERVED
# model id of the model under test (which varies per trial).
python3 "$REPO_ROOT/harness/telemetry.py" --trial "$OUT" --agent "$AGENT" \
  --provider "$PROVIDER_ID" --model "$MODEL_SERVED"

log "$TRIAL_ID: archived to $OUT"
