# M² Paper

LaTeX source for the M² paper (15-page conference-style presentation).

## Build

```sh
latexmk -pdf main.tex
```

To clean intermediate files:

```sh
latexmk -C
```

## Layout

- `main.tex` — preamble, abstract, acknowledgments, disclosures, appendices.
- `sections/01..08.tex` — body sections: introduction, background, protocol, formal invariants, economic analysis, numerical results + cross-protocol comparison, limitations, conclusion.
- `references.bib` — 41 BibTeX entries (20 cited in the current body).
- `figures/` — three body figures plus extended-artifact figures referenced from the Zenodo bundle.
- `supplementary-threat-model.tex` — standalone supplementary file with the full 14-row threat-model table. Compiles independently (`latexmk -pdf supplementary-threat-model.tex`); not bound into `main.pdf`.

## Content summary

- 8 body sections (§1 Introduction through §8 Conclusion) + 2 appendices (A Symbol Table, B Auxiliary Theorems housing the MEV bound).
- 10 formal blocks: Lemma L (integer-arithmetic redemption), Theorems T1–T6 in body, T7 in Appendix B, Corollary C1, Conjecture (LVR / floor-capture).
- 20 labeled equations.
- 3 body figures: architecture (inline TikZ), floor-trajectory, attacker-phasediagram.
- 4 tables in `main.pdf` (baseline 12-month, protocol comparison, condensed threat model, symbols) + 1 in the supplementary (full 14-row threat model).
- All math (theorem statements, proofs, numerical constants) is reproducible to 60-digit `Decimal` precision via the simulator at the Zenodo DOI in the abstract.

## Typography

The variant uses tighter-than-default density to fit 15 pages: `margin=0.85in`, `\linespread{0.97}`, `\footnotesize` bibliography, `\scriptsize` symbol-table and condensed threat-model, `\setlist{nosep}`, `\setlength{\bibsep}{1pt}`, and `\titlespacing*` tuning. If a venue mandates the default `1in` / `\linespread{1}` density, expect the paper to land at ~17–18 pages and rebudget accordingly.

## Reproducibility

Zenodo DOI in the abstract; git tag `v0.2.0-paper-v2` pins the version cited.
