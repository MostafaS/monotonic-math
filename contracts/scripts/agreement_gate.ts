// SPDX-License-Identifier: MIT
//
// Agreement Gate — TypeScript side
// =================================
//
// Compares the M² TypeScript reference model's deterministic baseline
// trajectory against the canonical Track A Python simulator's CSV output
// at `../simulation/outputs/`. Exits 0 on agreement within documented
// tolerance, 1 on disagreement.
//
// The TS model runs in "fee-free" mode here to match the paper §6 Table 1
// convention used by the canonical simulator. The with-fees comparison
// lives at Phase 6 (differential testing against the on-chain bytecode).
//
// Output: a small per-month CSV emitted to test/reference/outputs/
// (consumed by the Python sibling `agreement_gate.py` for cross-validation).
//
// Run via: `npm run test:agreement`

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DEFAULT_CONFIG,
  M2Config,
  canonicalGenesis,
  deterministicBaseline,
} from "../test/reference/M2ReferenceModel.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SIM_OUT = resolve(HERE, "../../simulation/outputs");
const TS_OUT = resolve(HERE, "../test/reference/outputs");

// =============================================================================
// Tolerances (documented)
// =============================================================================
//
// Source-of-truth: the canonical Track A Python simulator at
// `/Users/mostafa/Documents/Personal_Projects/M2/simulation/generate_figures.py`
// produces 36-month trajectories in float64. Float64 has ~15.95 significant
// decimal digits; over 36 months of recurrence the accumulated relative
// error is bounded by O(36 * 2^-53) ≈ 4e-15 rel. The TS bigint model is
// exact within its integer-unit grid (6-decimal stable, 18-decimal token).
//
// We compare the TS bigint state to the Python float CSV using:
//   absolute tolerance 1e-3 (stable units / token units) — well above the
//   integer-truncation grid (1 unit) and below any meaningful $ error.
//   relative tolerance 1e-9 — six orders of magnitude above float64 ULP.
//
// Disagreement at this tolerance indicates either:
//   (a) a real model bug (rounding direction, fee-mode mismatch), OR
//   (b) the Python CSV has been regenerated under different conventions
//       (e.g., with-fees re-introduced into the baseline).
// Either is a paper-stopping bug per paper §6.1.
const ABS_TOL = 1e-3;
const REL_TOL = 1e-9;

// =============================================================================
// CSV utilities
// =============================================================================

interface CsvRow { [k: string]: string; }

function parseCsv(path: string): CsvRow[] {
  const text = readFileSync(path, "utf8");
  const lines = text.split(/\r?\n/).filter(l => l.length > 0);
  if (lines.length === 0) return [];
  const header = lines[0].split(",");
  return lines.slice(1).map(line => {
    const cells = line.split(",");
    const row: CsvRow = {};
    header.forEach((h, i) => (row[h] = cells[i]));
    return row;
  });
}

function withinTol(a: number, b: number, abs: number, rel: number): boolean {
  return Math.abs(a - b) <= Math.max(abs, rel * Math.abs(b));
}

// =============================================================================
// Comparison
// =============================================================================

interface Discrepancy {
  month: number;
  field: string;
  ts: number;
  csv: number;
  diff: number;
}

function compareTrajectory(
  csvPath: string,
  monthlyRevenueDollars: number,
  nMonths: number,
): Discrepancy[] {
  if (!existsSync(csvPath)) {
    throw new Error(`Missing CSV ${csvPath} — run 'python3 ../simulation/generate_figures.py' first.`);
  }
  const rows = parseCsv(csvPath);
  if (rows.length !== nMonths + 1) {
    throw new Error(`CSV ${csvPath} has ${rows.length} rows; expected ${nMonths + 1}`);
  }

  const cfg: M2Config = { ...DEFAULT_CONFIG, feeMode: "fee-free" };
  const dollar = 10 ** cfg.stableDecimals;
  const token = 1e18;
  const snaps = deterministicBaseline(
    BigInt(monthlyRevenueDollars) * 10n ** BigInt(cfg.stableDecimals),
    nMonths,
    canonicalGenesis(cfg),
    cfg,
  );

  const out: Discrepancy[] = [];
  for (let m = 0; m <= nMonths; m++) {
    const row = rows[m];
    const s = snaps[m];
    const T = Number(s.state.T) / dollar;
    const S = Number(s.state.S) / token;
    const Lt = Number(s.state.Lt) / token;
    const Ls = Number(s.state.Ls) / dollar;
    const F = Number(s.floor18) / 1e18;
    const P = Number(s.spot18) / 1e18;

    const checks: [string, number, number][] = [
      ["treasury", T, Number(row.treasury)],
      ["supply", S, Number(row.supply)],
      ["lp_tokens", Lt, Number(row.lp_tokens)],
      ["lp_stable", Ls, Number(row.lp_stable)],
      ["floor", F, Number(row.floor)],
      ["spot", P, Number(row.spot)],
    ];
    for (const [field, ts, csv] of checks) {
      if (!withinTol(ts, csv, ABS_TOL, REL_TOL)) {
        out.push({ month: m, field, ts, csv, diff: ts - csv });
      }
    }
  }
  return out;
}

function emitTsTrajectory(
  outPath: string, monthlyRevenueDollars: number, nMonths: number,
): void {
  const cfg: M2Config = { ...DEFAULT_CONFIG, feeMode: "fee-free" };
  const dollar = 10 ** cfg.stableDecimals;
  const token = 1e18;
  const snaps = deterministicBaseline(
    BigInt(monthlyRevenueDollars) * 10n ** BigInt(cfg.stableDecimals),
    nMonths,
    canonicalGenesis(cfg),
    cfg,
  );
  const header = "month,treasury,supply,floor,lp_tokens,lp_stable,spot\n";
  const body = snaps.map(s => {
    const T = Number(s.state.T) / dollar;
    const S = Number(s.state.S) / token;
    const Lt = Number(s.state.Lt) / token;
    const Ls = Number(s.state.Ls) / dollar;
    const F = Number(s.floor18) / 1e18;
    const P = Number(s.spot18) / 1e18;
    return [s.month, T, S, F, Lt, Ls, P].map(v => String(v)).join(",");
  }).join("\n") + "\n";
  writeFileSync(outPath, header + body);
}

// =============================================================================
// Main
// =============================================================================

function main(): number {
  console.log("M² Agreement Gate (TS) — comparing TS reference model vs. Track A CSV");
  console.log(`  TS reference: contracts/test/reference/M2ReferenceModel.ts`);
  console.log(`  Track A CSV : ${SIM_OUT}`);
  console.log(`  Tolerance   : abs ${ABS_TOL}, rel ${REL_TOL} (fee-free mode)`);
  console.log();

  // Ensure TS output directory exists so the Python sibling can find our CSVs.
  mkdirSync(TS_OUT, { recursive: true });

  let allFails: Discrepancy[] = [];
  const scenarios: Array<[string, string, number, number]> = [
    ["baseline_12mo", "baseline_12mo.csv", 100_000, 12],
    ["baseline_36mo", "baseline_36mo.csv", 100_000, 36],
  ];
  for (const [name, csvName, rev, n] of scenarios) {
    const csvPath = resolve(SIM_OUT, csvName);
    console.log(`[${name}] revenue=$${rev}/mo, months=${n}`);
    const fails = compareTrajectory(csvPath, rev, n);
    if (fails.length === 0) {
      console.log(`  PASS (${n + 1} rows, 6 fields each = ${(n + 1) * 6} checks)`);
    } else {
      console.log(`  FAIL: ${fails.length} discrepancies`);
      for (const d of fails.slice(0, 10)) {
        console.log(
          `    month=${d.month} field=${d.field} ts=${d.ts} csv=${d.csv} diff=${d.diff}`,
        );
      }
      if (fails.length > 10) console.log(`    ... and ${fails.length - 10} more`);
    }
    // Emit TS trajectory for the Python sibling.
    const outPath = resolve(TS_OUT, `${name}_ts.csv`);
    emitTsTrajectory(outPath, rev, n);
    console.log(`  wrote TS trajectory → ${outPath}`);
    allFails = allFails.concat(fails);
    console.log();
  }

  if (allFails.length > 0) {
    console.log(`AGREEMENT GATE FAILED: ${allFails.length} total discrepancies`);
    return 1;
  }
  console.log("AGREEMENT GATE PASSED");
  return 0;
}

process.exit(main());
