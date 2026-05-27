# Monotonic Math (M²)

A provably floor-preserving tokenomic primitive for revenue-bearing on-chain assets.

[![Paper PDF](https://img.shields.io/badge/paper-PDF-blue)](paper/main.pdf)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20255140.svg)](https://doi.org/10.5281/zenodo.20255140)

> **Latest release:** `v0.2.0-paper-v2` — conference-length (15-page) presentation of the paper. All theorems, proofs, and numerical constants preserved verbatim from the prior `v0.1.2-paper-v1` long-form release. The concept DOI `10.5281/zenodo.20255140` above resolves to the current version.

## Overview

M² ("Monotonic Math") is a tokenomic primitive that combines four immutable contracts — a fixed-supply ERC-20 token with redemption, a passive stablecoin treasury, a Uniswap-v4 hook implementing asymmetric per-swap fees, and a 50/50 revenue router — to enforce a contractually monotone non-decreasing redemption floor. Under every protocol-defined operation (buy, sell, redeem, transfer, revenue distribution, fee collection), the per-token claim on the treasury is provably non-decreasing.

The central theorem (paper §4) states the floor

$$F_t \;=\; \frac{T_t}{N_t}$$

where `T_t` is the stablecoin treasury balance and `N_t` is the circulating token supply, is monotone non-decreasing under every protocol-defined state transition. Buys do not move the floor; sells, redemptions, and revenue deposits strictly raise it. The protocol gracefully degrades to a closed-end-fund analog at zero revenue: the floor stops compounding, but it does not retreat.

This repository contains:

- **The paper** ([`paper/main.pdf`](paper/main.pdf)) — the formal write-up of the protocol, its proofs, the operating envelope, and the numerical evaluation. LaTeX sources are in [`paper/`](paper/). The paper is the authoritative specification.
- **The simulator** ([`simulation/`](simulation/)) — a Python script that regenerates every figure in the paper from the closed-form deterministic recurrence and a Monte Carlo wrapper.
- **Contracts** ([`contracts/`](contracts/)) — placeholder. The Solidity reference implementation will land here.

## Quick start

### Read the paper

The pre-built PDF lives at [`paper/main.pdf`](paper/main.pdf). To rebuild from source you need a TeX Live distribution (MacTeX, TeX Live, or MiKTeX).

```bash
cd paper
pdflatex main.tex
bibtex main
pdflatex main.tex
pdflatex main.tex
```

Or, with `latexmk` (recommended):

```bash
cd paper
latexmk -pdf main.tex
```

**macOS PATH note.** A fresh `brew install --cask mactex-no-gui` installs binaries at `/Library/TeX/texbin` but doesn't put them on the current shell's PATH until you open a new terminal. One-shot workaround in the current shell:

```bash
eval "$(/usr/libexec/path_helper)"
```

See [`paper/README.md`](paper/README.md) for full build details and the typography deviations the 15-page variant uses.

### Regenerate the figures

The simulator reproduces all eight figures of the long-form §6 deterministically — the conference-length paper embeds two of them (floor-trajectory, attacker-phasediagram) in the body and references the rest as Zenodo-artifact extensions. Tested on Python 3.10+.

```bash
cd simulation
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 generate_figures.py
```

Output PDFs and PNGs are written to `../paper/figures/`. The script is deterministic — the figures regenerate bit-identically (up to matplotlib version drift in font rendering) on every run.

## Repository layout

```
.
├── README.md
├── LICENSE
├── CITATION.cff
├── .gitignore
├── paper/                 LaTeX source for the paper
│   ├── main.tex
│   ├── main.pdf
│   ├── references.bib
│   ├── sections/          one .tex file per section
│   ├── figures/           generated PDFs/PNGs (see simulation/)
│   ├── supplementary-threat-model.tex  standalone supplementary
│   └── README.md          build instructions
├── simulation/            Python figure generator
│   ├── generate_figures.py
│   └── requirements.txt
└── contracts/             Solidity reference implementation (placeholder)
    └── README.md
```

## Citation

If you use M² in academic work, please cite the paper:

```bibtex
@misc{Sadjadi2026MonotonicMath,
  author       = {Sadjadi, Mostafa},
  title        = {Monotonic Math: A Provably Floor-Preserving Tokenomic
                  Primitive for Revenue-Bearing On-Chain Assets},
  year         = {2026},
  howpublished = {Working paper / preprint},
  doi          = {10.5281/zenodo.20255141},
  url          = {https://doi.org/10.5281/zenodo.20255141},
  note         = {Zenodo deposit v0.2.0-paper-v2. ORCID: 0009-0005-2573-3336.}
}
```

A `CITATION.cff` file is included so GitHub renders a "Cite this repository" button on the project page.

ORCID: [0009-0005-2573-3336](https://orcid.org/0009-0005-2573-3336)

## License

MIT — see [`LICENSE`](LICENSE). The mechanism is released as a non-proprietary tokenomics primitive available to any DeFi project; the author claims no proprietary rights over the design.

## Disclosures

The following disclosures mirror the *Disclosures* section of the paper.

**Funding.** This research was conducted independently by the author without external funding.

**Conflict of interest.** The author intends to deploy a reference implementation of the M² protocol described in this paper. The mechanism is intended for open-source release as a non-proprietary tokenomics primitive available to any DeFi project; the author claims no proprietary rights over the design and does not hold a financial interest in any specific instance of the protocol beyond the reference deployment. Readers should weigh this intended deployment when interpreting the qualitative framing of the paper, though all quantitative claims are derivable from the protocol specification and the closed-form analysis of paper §§4–5 and do not depend on any operational assumption about a specific deployment.

**Code and data availability.** The simulator code and figure-generation scripts are in this repository under the MIT License. The reference contract implementation will be developed in [`contracts/`](contracts/) and released under the same license. The v0.2.0-paper-v2 artifact is deposited on Zenodo: version DOI [10.5281/zenodo.20255141](https://doi.org/10.5281/zenodo.20255141); the concept DOI [10.5281/zenodo.20255140](https://doi.org/10.5281/zenodo.20255140) tracks subsequent versions and resolves to the latest.
