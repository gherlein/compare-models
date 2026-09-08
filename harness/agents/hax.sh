#!/usr/bin/env bash
# hax adapter. Sourced by trial.sh / config-smoke.sh via load_agent().
# Contract and the globals the caller sets are documented in harness/agents/omp.sh.

agent_version() { hax --version; }

agent_run() {
  local tree="$1" out="$2" trial_id="$3" max_time="$4" prompt_file="$5"
  local cfg="$out/config"

  python3 "$REPO_ROOT/harness/render_config.py" --agent hax \
    --base-url "$OPENAI_BASE_URL" --provider "$PROVIDER_ID" --api-key "$API_KEY" \
    --model-file "$MODEL_ENTRY_FILE" --out-dir "$cfg" >/dev/null \
    || die "render_config hax failed for model $MODEL_ID"

  # hax follows XDG paths for everything: config, remembered selections,
  # sessions, model-metadata cache. Pointing all three roots into the trial's
  # output directory both isolates the trial from the operator's own hax setup
  # and puts the session jsonl where the harness archives it.
  mkdir -p "$out/xdg/config/hax" "$out/xdg/state" "$out/xdg/cache"
  cp "$cfg/hax-config.json" "$out/xdg/config/hax/config.json"

  # hax has no --cwd flag; the subshell scopes the cd and the env to this run.
  # stdin is closed: with a prompt argument hax must not read a piped stdin.
  # GOCACHE is pinned because Go derives its default from XDG_CACHE_HOME:
  # without the pin, go builds run by hax's bash tool pay a cold per-trial build
  # cache while a different agent's untouched subprocesses use the operator's
  # warm one -- an asymmetry inside the timed window.
  (
    cd "$tree" || exit 1
    GOCACHE="${GOCACHE:-$HOME/.cache/go-build}" \
    XDG_CONFIG_HOME="$out/xdg/config" \
    XDG_STATE_HOME="$out/xdg/state" \
    XDG_CACHE_HOME="$out/xdg/cache" \
    timeout --signal=TERM --kill-after=60s "$max_time" \
      hax -p "$(cat "$prompt_file")" \
      < /dev/null > "$out/agent.out" 2> "$out/agent.err"
  )
}
