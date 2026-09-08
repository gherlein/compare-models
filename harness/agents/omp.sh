#!/usr/bin/env bash
# omp adapter. Sourced by trial.sh / config-smoke.sh via load_agent().
#
# Adapter contract (every file in harness/agents/ implements it):
#   agent_version                                  -> echo a version string
#   agent_run TREE OUT TRIAL_ID MAX_TIME PROMPT_FILE
#     Run the chosen agent non-interactively in TREE with the prompt from
#     PROMPT_FILE, under an external `timeout MAX_TIME` so the cap mechanism is
#     identical for every agent. Write stdout/stderr to OUT/agent.out and
#     OUT/agent.err and the session record somewhere under OUT that
#     telemetry.py's parser for this agent knows to read. Return the agent's
#     exit code (124 when the external cap killed it).
#
# The MODEL is the variable in compare-models, so the caller (trial.sh /
# config-smoke.sh) sets these globals before calling agent_run, and the adapter
# renders this model's config with harness/render_config.py:
#   MODEL_ID          short id of the model under test (results grouping)
#   MODEL_SERVED      the model id the server reports and the agent selects
#   MODEL_ENTRY_FILE  path to the model's entry JSON (fed to render_config.py)
#   OPENAI_BASE_URL, PROVIDER_ID, API_KEY   platform constants (from lib.sh)
# The rendered config is written under OUT/config and archived, so the exact
# configuration a trial ran under is always recoverable.

agent_version() { omp --version | tail -1; }

agent_run() {
  local tree="$1" out="$2" trial_id="$3" max_time="$4" prompt_file="$5"
  local profile="bench-$trial_id" dir exit_code cfg="$out/config"

  python3 "$REPO_ROOT/harness/render_config.py" --agent omp \
    --base-url "$OPENAI_BASE_URL" --provider "$PROVIDER_ID" --api-key "$API_KEY" \
    --model-file "$MODEL_ENTRY_FILE" --out-dir "$cfg" >/dev/null \
    || die "render_config omp failed for model $MODEL_ID"

  # `omp --profile` isolates models.yml along with auth, sessions, settings and
  # caches, so a throwaway profile has no custom providers and every trial would
  # die with "No models available". Seed the rendered provider definition in
  # before omp runs. The destination comes from omp itself so a change to omp's
  # profile layout cannot silently put the file somewhere omp no longer reads.
  dir="$(omp --profile "$profile" config path)" \
    || die "cannot resolve omp profile dir for $profile"
  [ -n "$dir" ] || die "omp returned an empty profile dir for $profile"
  mkdir -p "$dir"
  cp "$cfg/models.yml" "$dir/models.yml"

  # stdin is closed: omp treats a pipe on stdin as piped input and blocks
  # waiting for EOF. The cap is external `timeout`, not omp's --max-time, so
  # every agent is stopped by the identical mechanism.
  timeout --signal=TERM --kill-after=60s "$max_time" \
    omp -p --profile "$profile" \
    --config "$cfg/omp-bench.yml" \
    --cwd "$tree" --session-dir "$out/session" \
    --no-skills --no-rules --no-extensions --no-title --auto-approve \
    "$(cat "$prompt_file")" \
    < /dev/null > "$out/agent.out" 2> "$out/agent.err"
  exit_code=$?

  # The profile is throwaway and the session already lives in OUT/session; the
  # guard keeps a surprising `config path` answer from deleting anything outside
  # the bench namespace.
  case "$dir" in
    "$HOME/.omp/profiles/bench-"*) rm -rf "$(dirname "$dir")" ;;
  esac

  return "$exit_code"
}
