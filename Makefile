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

# Force /bin/bash for the chained recipes (npm scripts assume bash arrays in
# package.json `test:unit` / `test:integration` / `test:invariant`).
SHELL       := /bin/bash

.PHONY: help install install-py install-node reproduce figures compile verify verify-full test fuzz fork clean
.DEFAULT_GOAL := help

help:
	@echo "M² Makefile targets"
	@echo ""
	@echo "First-time setup (run once after cloning):"
	@echo "  make install        pip install simulator deps + npm ci in contracts/"
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

install-py:
	cd $(SIMULATION) && $(PYTHON) -m pip install --upgrade pip
	cd $(SIMULATION) && $(PYTHON) -m pip install -r requirements.txt

install-node:
	cd $(CONTRACTS) && $(NPM) ci

# ---------------------------------------------------------------------------
# Track A — Python simulator regenerates every paper figure deterministically.
# Track B — Hardhat v3 compile (solc 0.8.34 exact, viaIR, cancun).
# ---------------------------------------------------------------------------

figures:
	$(PYTHON) $(SIMULATION)/generate_figures.py

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
	@echo "[make verify-full] Ready for the paper-v1 tag."

# ---------------------------------------------------------------------------
# Hygiene
# ---------------------------------------------------------------------------

clean:
	cd $(CONTRACTS) && $(NPM) run clean || true
	find $(SIMULATION) -type d -name __pycache__ -prune -exec rm -rf {} +
	@echo "[make clean] Hardhat artifacts + Python caches removed."
