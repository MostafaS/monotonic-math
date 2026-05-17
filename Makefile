# =============================================================================
# M² — Project-root Makefile
# =============================================================================
#
# Single source of truth for reproducing the paper artifacts and exercising
# the contract gates. See REPRODUCIBILITY.md for prerequisites and a full
# walkthrough.
#
# Track A (Python simulator) lives at simulation/.
# Track B (Solidity reference) lives at contracts/.
#
# Standard targets:
#   make reproduce     — regenerate paper figures (Track A) + compile (Track B)
#   make verify        — `reproduce` + contracts/ `npm run ci` (fast gate)
#   make verify-full   — `verify` + invariant:full + mainnet-fork (pre-tag)
#
# Aliases:
#   make figures       — Track A figure regeneration only
#   make compile       — contracts/ compile only
#   make test          — alias of `verify`
#   make fuzz          — invariant fast gate only
#   make clean         — wipe Hardhat artifacts + Python __pycache__
# =============================================================================

PYTHON      ?= python3
NPM         ?= npm
CONTRACTS   := contracts
SIMULATION  := simulation
VENV_DIR    := $(SIMULATION)/.venv
VENV_PY     := $(VENV_DIR)/bin/python

# Force /bin/bash for the chained recipes (npm scripts assume bash arrays in
# package.json `test:unit` / `test:integration` / `test:invariant`).
SHELL       := /bin/bash

.PHONY: help install install-py install-node reproduce figures compile verify verify-full test fuzz fork clean
.DEFAULT_GOAL := help

help:
	@echo "M² Makefile targets"
	@echo ""
	@echo "First-time setup (run once after cloning):"
	@echo "  make install        venv + pip install simulator deps + npm ci in contracts/"
	@echo ""
	@echo "Main targets:"
	@echo "  make reproduce      Regenerate paper figures (Track A) + compile (Track B)"
	@echo "  make verify         reproduce + contracts/ 'npm run ci' (~5 min)"
	@echo "  make verify-full    verify + invariant:full + mainnet-fork (~30 min)"
	@echo ""
	@echo "Aliases:"
	@echo "  make install-py     Python simulator dependencies only"
	@echo "  make install-node   contracts/ 'npm ci' only"
	@echo "  make figures        Track A figure regeneration only"
	@echo "  make compile        contracts/ compile only"
	@echo "  make fuzz           invariant fast gate only"
	@echo "  make fork           mainnet-fork test gate (requires MAINNET_RPC_URL keystore)"
	@echo "  make test           alias of 'make verify'"
	@echo "  make clean          wipe Hardhat artifacts + Python __pycache__"
	@echo ""
	@echo "See REPRODUCIBILITY.md for prerequisites + secret-key setup."

# ---------------------------------------------------------------------------
# Install (idempotent; run once per fresh clone or after a dependency bump)
# ---------------------------------------------------------------------------

install: install-py install-node
	@echo ""
	@echo "[make install] Python + Node dependencies installed. Run 'make verify' next."

# `install-py` creates an isolated venv under simulation/.venv/ so that the
# `pip install` lines below do not collide with PEP 668's externally-managed
# marker on Homebrew Python / Debian 12+ / Ubuntu 24.04+. The venv guard is
# idempotent: a second `make install-py` skips the venv create and re-runs
# pip, which is a near-no-op for already-satisfied requirements.
install-py:
	@if [ ! -x $(VENV_PY) ]; then \
		echo "[install-py] Creating virtualenv at $(VENV_DIR)/"; \
		$(PYTHON) -m venv $(VENV_DIR); \
	else \
		echo "[install-py] Reusing existing virtualenv at $(VENV_DIR)/"; \
	fi
	$(VENV_PY) -m pip install --upgrade pip
	$(VENV_PY) -m pip install -r $(SIMULATION)/requirements.txt
	@echo "[install-py] Done. Activate with: source $(VENV_DIR)/bin/activate"

install-node:
	cd $(CONTRACTS) && $(NPM) ci

# ---------------------------------------------------------------------------
# Track A — Python simulator regenerates every paper figure deterministically.
# Track B — Hardhat v3 compile (solc 0.8.34 exact, viaIR, cancun).
# ---------------------------------------------------------------------------

# `figures` auto-detects the simulator venv at recipe-execution time. A
# `make` variable defined with `$(shell ...)` would be evaluated once at
# parse time and cached for the life of the process — that breaks the
# `make install && make figures` chain in a single invocation where the
# venv only exists after `install` runs. The bash conditional below is
# re-evaluated on every recipe run, so it correctly picks up a freshly
# created venv. Falls back to $(PYTHON) so users with global numpy /
# matplotlib who skipped `make install` still get a working `make figures`.
figures:
	@if [ -x $(VENV_PY) ]; then \
		echo "[figures] Using venv interpreter $(VENV_PY)"; \
		$(VENV_PY) $(SIMULATION)/generate_figures.py; \
	else \
		echo "[figures] No venv found; falling back to system $(PYTHON)"; \
		$(PYTHON) $(SIMULATION)/generate_figures.py; \
	fi

compile:
	cd $(CONTRACTS) && $(NPM) run compile

reproduce: figures compile
	@echo ""
	@echo "[make reproduce] Track A figures regenerated under paper/figures/."
	@echo "[make reproduce] Track B contracts compiled (solc 0.8.34)."

# ---------------------------------------------------------------------------
# Fast verify gate — runs on every PR via .github/workflows/ci.yml.
# Mirrors `npm run ci`: compile + check:pragma + check:hook-salt + lint +
# audit:bytecode + audit:inheritance + test:reference + test:agreement +
# test:local + test:invariant.
# ---------------------------------------------------------------------------

verify: reproduce
	cd $(CONTRACTS) && $(NPM) run ci
	@echo "[verify] Writing SHA-256 manifest of regenerated artifacts..."
	@# Portable across macOS and Linux: prefer `shasum -a 256` (BSD-derived;
	@# present on macOS by default), fall back to GNU `sha256sum`. The
	@# manifest covers every regenerated paper figure (PDF + PNG) and every
	@# Track-A simulator output under simulation/outputs/. Paths in the
	@# manifest are relative to the project root so reviewers can re-verify
	@# with a single `shasum -a 256 -c MANIFEST.sha256` from the same dir.
	@HASHER=$$( command -v shasum >/dev/null 2>&1 && echo "shasum -a 256" || echo "sha256sum" ); \
	  : > MANIFEST.sha256.tmp; \
	  (cd paper/figures && $$HASHER *.pdf *.png 2>/dev/null | sed 's|^\([0-9a-f]*  \)|\1paper/figures/|') >> MANIFEST.sha256.tmp; \
	  (cd $(SIMULATION)/outputs && $$HASHER * 2>/dev/null | sed 's|^\([0-9a-f]*  \)|\1$(SIMULATION)/outputs/|') >> MANIFEST.sha256.tmp; \
	  mv MANIFEST.sha256.tmp MANIFEST.sha256; \
	  echo "[verify] Wrote MANIFEST.sha256 ($$(wc -l < MANIFEST.sha256 | tr -d ' ') entries)"

test: verify

fuzz:
	cd $(CONTRACTS) && $(NPM) run test:invariant

# ---------------------------------------------------------------------------
# Full pre-tag gate — adds the Phase-4 acceptance-scale invariant suite and
# the mainnet-fork integration tests. The fork gate requires a
# MAINNET_RPC_URL in the Hardhat keystore (see contracts/KEYSTORE.md);
# without it the @fork tests skip cleanly.
# ---------------------------------------------------------------------------

fork:
	cd $(CONTRACTS) && M2_ENABLE_FORK_TESTS=1 $(NPM) run test:fork

verify-full: verify
	cd $(CONTRACTS) && $(NPM) run test:invariant:full
	cd $(CONTRACTS) && M2_ENABLE_FORK_TESTS=1 $(NPM) run test:fork
	@echo ""
	@echo "[make verify-full] All Phase-4 + Phase-6 gates passed."
	@echo "[make verify-full] Ready for the v0.1.1-paper-v1 tag."

# ---------------------------------------------------------------------------
# Hygiene
# ---------------------------------------------------------------------------

clean:
	cd $(CONTRACTS) && $(NPM) run clean || true
	find $(SIMULATION) -type d -name __pycache__ -prune -exec rm -rf {} +
	rm -f MANIFEST.sha256 MANIFEST.sha256.tmp
	@echo "[make clean] Hardhat artifacts + Python caches + MANIFEST.sha256 removed."
