#!/usr/bin/env bash
# pi adapter. Sourced by trial.sh / config-smoke.sh via load_agent().
# Contract and the globals the caller sets are documented in harness/agents/omp.sh.
#
# pi is @earendil-works/pi-coding-agent -- the lean TypeScript upstream that omp
# forked. It has NONE of omp's --cwd / --config / --profile / --auto-approve
# flags: the working directory is the process cwd, the provider lives in a
# models.json under the agent dir, print mode runs tools with no approval gate,
# and state is isolated by relocating the agent dir.

agent_version() { pi --version; }

agent_run() {
  local tree="$1" out="$2" trial_id="$3" max_time="$4" prompt_file="$5"
  local cfg="$out/config"

  python3 "$REPO_ROOT/harness/render_config.py" --agent pi \
    --base-url "$OPENAI_BASE_URL" --provider "$PROVIDER_ID" --api-key "$API_KEY" \
    --model-file "$MODEL_ENTRY_FILE" --out-dir "$cfg" >/dev/null \
    || die "render_config pi failed for model $MODEL_ID"

  # pi has no --config flag. A custom provider is defined in models.json inside
  # the agent dir (default ~/.pi/agent, relocatable via PI_CODING_AGENT_DIR).
  # Seed the rendered bench provider there before pi runs. The agent dir is
  # per-trial, so no auth/session/catalog state leaks between trials.
  local agent_dir="$out/home/.pi/agent"
  mkdir -p "$agent_dir"
  cp "$cfg/pi-models.json" "$agent_dir/models.json"

  # pi has no --cwd flag; the subshell scopes the cd and the env to this run.
  # HOME + PI_CODING_AGENT_DIR both point the agent dir at the trial output so
  # the seeded models.json is found and any state stays per-trial. GOCACHE is
  # pinned for the same reason as the hax adapter.
  #
  # --print is non-interactive; --offline disables pi's startup network calls
  # (catalog refresh / update checks) without affecting inference -- the "no
  # network beyond the inference server" control. --no-skills / --no-extensions
  # / --no-prompt-templates / --no-context-files strip pi's optional discovery
  # surfaces. The cap is external `timeout`, identical to the other agents.
  (
    cd "$tree" || exit 1
    HOME="$out/home" \
    PI_CODING_AGENT_DIR="$agent_dir" \
    GOCACHE="${GOCACHE:-$HOME/.cache/go-build}" \
    timeout --signal=TERM --kill-after=60s "$max_time" \
      pi --print --offline \
        --model "$PROVIDER_ID/$MODEL_SERVED" \
        --session-dir "$out/session" \
        --no-skills --no-extensions --no-prompt-templates --no-context-files \
        "$(cat "$prompt_file")" \
      < /dev/null > "$out/agent.out" 2> "$out/agent.err"
  )
}
