#!/usr/bin/env bash
# kit adapter. Sourced by trial.sh / config-smoke.sh via load_agent().
# Contract and the globals the caller sets are documented in harness/agents/omp.sh.
#
# kit is github.com/mark3labs/kit, a native Go agent. Rendered routing and
# sampling live in this model's kit-bench.yml (passed with --config); this
# adapter handles isolation, provider seeding, and the non-interactive call.

agent_version() { kit --version; }

agent_run() {
  local tree="$1" out="$2" trial_id="$3" max_time="$4" prompt_file="$5"
  local cfg="$out/config"

  python3 "$REPO_ROOT/harness/render_config.py" --agent kit \
    --base-url "$OPENAI_BASE_URL" --provider "$PROVIDER_ID" --api-key "$API_KEY" \
    --model-file "$MODEL_ENTRY_FILE" --out-dir "$cfg" >/dev/null \
    || die "render_config kit failed for model $MODEL_ID"

  # kit resolves its session dir from $HOME (~/.kit/sessions) and its config
  # from $XDG_CONFIG_HOME. Pointing both into the trial output isolates the
  # trial and puts the session JSONL where the harness archives it and
  # telemetry.py reads it. A fresh HOME has no ~/.kit.yml, so the only
  # configuration kit sees is the one --config points at.
  #
  # Provider registration: this kit build has no config-file `providers:`
  # section, so the provider must exist in kit's models.dev cache at
  # $XDG_DATA_HOME/kit/providers.json (default $HOME/.local/share/kit). Seed the
  # rendered cache there so kit resolves <provider>/<model> and auto-routes it
  # through @ai-sdk/openai-compatible to the platform. This lands in the
  # isolated trial HOME, so it never touches the operator's kit.
  mkdir -p "$out/home/.config" "$out/home/.local/share/kit"
  cp "$cfg/kit-bench-providers.json" \
     "$out/home/.local/share/kit/providers.json"

  # kit has no --cwd flag; the subshell scopes the cd and the env to this run.
  # stdin is closed. GOCACHE is pinned for the same reason as the hax adapter.
  # --max-steps 0 removes kit's step cap so the wall-clock cap is the only limit.
  # --quiet / --no-extensions / --no-prompt-templates strip kit's optional
  # plugin/rule surfaces so the measured behavior is kit's core loop. A session
  # is persisted by default, which is what telemetry.py parses.
  (
    cd "$tree" || exit 1
    HOME="$out/home" \
    XDG_CONFIG_HOME="$out/home/.config" \
    KIT_BENCH_KEY="$API_KEY" \
    GOCACHE="${GOCACHE:-$HOME/.cache/go-build}" \
    timeout --signal=TERM --kill-after=60s "$max_time" \
      kit --config "$cfg/kit-bench.yml" \
        --quiet --no-extensions --no-prompt-templates \
        --max-steps 0 \
        "$(cat "$prompt_file")" \
      < /dev/null > "$out/agent.out" 2> "$out/agent.err"
  )
}
