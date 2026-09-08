# compare-models: vary the MODEL, hold the agent and platform constant.
# TARGET selects the platform (dgx = sglang/GB10, default; local = Lemonade).
# AGENT selects the one fixed coding agent (omp default; hax|kit|pi).
# The set of models compared lives in config/$(TARGET)/models.json.
#
#   make preflight
#   make run-all TRIALS=1                     # every model in the set
#   make run-all TRIALS=5 MODEL=qwen3-27b-nvfp4   # one model's batch
#   make score
#   make run-all AGENT=hax TARGET=local       # a different fixed agent/platform
#   make compare ARGS="dgx/omp dgx/hax"       # ranking under two agents

TRIALS ?= 1
TARGET ?= dgx
AGENT  ?= omp
export TARGET AGENT

.DEFAULT_GOAL := help

.PHONY: help build test run-tests preflight config-smoke anchor-selftest trial run-all score compare clean

help:
	@echo "Vary the model; agent and platform are fixed (AGENT=$(AGENT), TARGET=$(TARGET))."
	@echo "Targets (run directly on the driver):"
	@echo "  preflight       verify the platform + chosen agent, write results/<t>/<a>/preflight.json"
	@echo "  config-smoke    prove the agent routes to the pinned provider/model (per model)"
	@echo "  anchor-selftest build the reference pngdec and run the frozen anchor suite against it"
	@echo "  trial           one trial: make trial MODEL=<id> N=1  (N=0 is a shakedown, never scored)"
	@echo "  run-all         TRIALS=$(TRIALS) trials per model; MODEL=<id> for a single model's batch"
	@echo "  score           anchor-ranked report + cross-matrix + time (builds the reference first)"
	@echo "  compare         side-by-side model ranking across evaluations: make compare ARGS=\"dgx/omp dgx/hax\""
	@echo "  build           build the reference pngdec binary"
	@echo "  clean           remove generated build artifacts and agent workspaces"

build:
	go build -C spec/reference -o "$(CURDIR)/spec/reference/pngdec-reference" .

anchor-selftest: build
	PNGDEC_BIN="$(CURDIR)/spec/reference/pngdec-reference" go test -C spec/anchor -count=1 -v ./...

test: anchor-selftest

run-tests: anchor-selftest

preflight:
	bash harness/preflight.sh

config-smoke:
	bash harness/config-smoke.sh $(MODEL)

trial:
	@test -n "$(MODEL)" || (echo "usage: make trial MODEL=<id> N=1" && exit 1)
	bash harness/trial.sh $(MODEL) $(N)

run-all:
	bash harness/run-all.sh $(TRIALS)

# Depends on anchor-selftest so the reference binary score.py needs for its
# over-strict check always exists first -- scoring without it would silently
# report every trial's suite as over-strict instead of failing.
score: anchor-selftest
	python3 harness/score.py

# Reads results/<target>/<agent>/scores.json for each evaluation named in ARGS
# (run `make score` for each first). Default: dgx/omp vs dgx/hax.
compare:
	python3 harness/compare.py $(ARGS)

clean:
	rm -rf spec/reference/pngdec-reference worktrees "$(HOME)/.cache/compare-models/worktrees"
