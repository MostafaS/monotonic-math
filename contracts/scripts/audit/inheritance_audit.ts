// SPDX-License-Identifier: MIT
//
// inheritance_audit.ts — Phase 8 forbidden-inheritance gate
// =========================================================
//
// Paper §3.1 forbids the four immutable contracts from inheriting any of:
//
//   - Ownable
//   - Ownable2Step
//   - AccessControl  (and AccessControlEnumerable, AccessControlDefaultAdminRules)
//   - Pausable
//   - UUPSUpgradeable
//
// FINAL_REPORT M3 elevates this to a structural check. Solhint cannot
// enforce inheritance patterns, so this script does it via direct source
// inspection. It walks each of the four immutable contract source files
// AND the genesis factory, builds the closure of their imports (limited to
// repository-local files; node_modules are NOT recursed), and asserts
// that no file in the closure declares a base type from the forbidden
// list.
//
// Mocks and tests are exempt and not scanned.
//
// Exit code is nonzero on any forbidden inheritance hit. Run via:
// `npm run audit:inheritance`.

import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CONTRACTS_ROOT = resolve(__dirname, "..", "..");

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

interface Target {
  label: string;
  sourcePath: string;
  /** Strict-mode targets: any forbidden base in the target file itself OR
   *  in any locally-imported file fails the audit. */
  strict: boolean;
}

const TARGETS: readonly Target[] = [
  {
    label: "M2Token",
    sourcePath: resolve(CONTRACTS_ROOT, "contracts/token/M2Token.sol"),
    strict: true,
  },
  {
    label: "M2Treasury",
    sourcePath: resolve(CONTRACTS_ROOT, "contracts/treasury/M2Treasury.sol"),
    strict: true,
  },
  {
    label: "M2RevenueRouter",
    sourcePath: resolve(CONTRACTS_ROOT, "contracts/router/M2RevenueRouter.sol"),
    strict: true,
  },
  {
    label: "M2V4Hook",
    sourcePath: resolve(CONTRACTS_ROOT, "contracts/hook/M2V4Hook.sol"),
    strict: true,
  },
  // Factory is one-shot deployer; not strictly under paper §3.1's four-
  // immutable rule, but we still flag if it picks up Ownable / etc.
  {
    label: "M2GenesisFactory",
    sourcePath: resolve(
      CONTRACTS_ROOT,
      "contracts/genesis/M2GenesisFactory.sol"
    ),
    strict: false,
  },
];

const FORBIDDEN_BASES: readonly string[] = [
  "Ownable",
  "Ownable2Step",
  "AccessControl",
  "AccessControlEnumerable",
  "AccessControlDefaultAdminRules",
  "Pausable",
  "UUPSUpgradeable",
];

// ---------------------------------------------------------------------------
// Inheritance extraction
// ---------------------------------------------------------------------------

interface InheritanceHit {
  file: string;
  line: number;
  declaration: string;
  forbiddenBase: string;
}

/**
 * Returns every forbidden base class that appears in `contract Foo is …`
 * or `abstract contract Foo is …` declarations within the source. We
 * intentionally do NOT match `interface ... is ...` (interfaces only
 * extend other interfaces; not a privilege carrier) but Solidity's syntax
 * for interfaces uses the same `is` keyword for parent interfaces, so we
 * include them — none of the forbidden names are interfaces anyway.
 */
function findForbiddenBases(file: string, src: string): InheritanceHit[] {
  const hits: InheritanceHit[] = [];
  const lines = src.split("\n");

  // Match: (abstract )? contract|interface NAME is BASE1, BASE2 ...
  // We work line-by-line because Solidity contract headers may span
  // multiple lines; we therefore additionally accumulate continuation
  // lines until we hit the opening `{`.
  for (let i = 0; i < lines.length; i += 1) {
    const head = lines[i];
    const isContractHead = /^\s*(abstract\s+)?(contract|interface)\s+\w+\s+is\b/.test(head);
    if (!isContractHead) continue;

    // Glue forward until `{`.
    let buf = head;
    let j = i;
    while (!buf.includes("{") && j + 1 < lines.length) {
      j += 1;
      buf += " " + lines[j];
    }
    const braceIdx = buf.indexOf("{");
    const decl = braceIdx >= 0 ? buf.slice(0, braceIdx) : buf;

    const isMatch = /\bis\b([^{]+)/.exec(decl);
    if (!isMatch) continue;

    const bases = isMatch[1]
      .split(",")
      .map((s) => s.trim().split("(")[0].trim())
      .filter((s) => s.length > 0);

    for (const base of bases) {
      if (FORBIDDEN_BASES.includes(base)) {
        hits.push({
          file,
          line: i + 1,
          declaration: decl.trim().replace(/\s+/g, " "),
          forbiddenBase: base,
        });
      }
    }
  }

  return hits;
}

// ---------------------------------------------------------------------------
// Local-import resolution
// ---------------------------------------------------------------------------

/**
 * Returns every locally-imported `.sol` file path (resolved to absolute)
 * from the given source. Imports that look like external packages
 * (anything starting with a letter, like `@openzeppelin/...` or
 * `@uniswap/...`) are NOT recursed — those are vetted dependencies, not
 * M² source.
 */
function findLocalImports(file: string, src: string): string[] {
  const out: string[] = [];
  const re = /import\s+(?:[^"';]+from\s+)?["']([^"']+)["']/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    const target = m[1];
    if (!target.startsWith(".") && !target.startsWith("/")) continue;
    const resolved = resolve(dirname(file), target);
    if (existsSync(resolved)) {
      out.push(resolved);
    }
  }
  return out;
}

/**
 * Builds the transitive closure of local imports starting at `entry`. The
 * closure does NOT include third-party / node_modules imports — those
 * are out of scope for this audit (OZ Ownable lives in node_modules and
 * is not a M²-authored hit by definition).
 */
function buildLocalClosure(entry: string): string[] {
  const seen = new Set<string>();
  const stack: string[] = [entry];
  while (stack.length > 0) {
    const cur = stack.pop()!;
    if (seen.has(cur)) continue;
    seen.add(cur);
    if (!existsSync(cur)) continue;
    const src = readFileSync(cur, "utf8");
    for (const imp of findLocalImports(cur, src)) {
      if (!seen.has(imp)) stack.push(imp);
    }
  }
  return Array.from(seen).sort();
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

interface Result {
  label: string;
  strict: boolean;
  scannedFiles: number;
  hits: InheritanceHit[];
}

function summarize(results: readonly Result[]): string {
  const lines: string[] = [];
  lines.push("Phase 8 — Inheritance audit");
  lines.push("=".repeat(40));
  lines.push(
    `Forbidden bases: ${FORBIDDEN_BASES.join(", ")}\n` +
      `(Mocks and tests are exempt and not scanned.)\n`
  );
  for (const r of results) {
    const marker = r.hits.length === 0 ? "OK" : "FAIL";
    lines.push(
      `  [${marker}] ${r.label}` +
        `${r.strict ? " [strict]" : ""}` +
        `  — ${r.scannedFiles} local files scanned, ` +
        `${r.hits.length} forbidden-base hit(s)`
    );
    for (const h of r.hits) {
      const rel = h.file.startsWith(CONTRACTS_ROOT)
        ? h.file.slice(CONTRACTS_ROOT.length + 1)
        : h.file;
      lines.push(
        `      ${rel}:${h.line}  is ${h.forbiddenBase}  ` +
          `(decl: ${h.declaration})`
      );
    }
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function main(): void {
  const results: Result[] = [];

  for (const target of TARGETS) {
    if (!existsSync(target.sourcePath)) {
      throw new Error(
        `audit:inheritance: source missing for ${target.label} at ${target.sourcePath}`
      );
    }
    const closure = buildLocalClosure(target.sourcePath);
    const hits: InheritanceHit[] = [];
    for (const file of closure) {
      const src = readFileSync(file, "utf8");
      hits.push(...findForbiddenBases(file, src));
    }
    results.push({
      label: target.label,
      strict: target.strict,
      scannedFiles: closure.length,
      hits,
    });
  }

  const report = summarize(results);
  process.stdout.write(`${report}\n`);

  const strictFailures = results.filter((r) => r.strict && r.hits.length > 0);
  const advisoryFailures = results.filter(
    (r) => !r.strict && r.hits.length > 0
  );

  if (strictFailures.length > 0) {
    process.stderr.write(
      `\naudit:inheritance FAILED — forbidden inheritance in paper-immutable ` +
        `contracts: ${strictFailures.map((r) => r.label).join(", ")}\n`
    );
    process.exit(1);
  }

  if (advisoryFailures.length > 0) {
    // Advisory only — does NOT fail CI, but does print.
    process.stdout.write(
      `\naudit:inheritance ADVISORY — non-strict targets with forbidden ` +
        `inheritance: ${advisoryFailures.map((r) => r.label).join(", ")}\n`
    );
  }

  process.stdout.write(
    `\naudit:inheritance OK — no forbidden inheritance in the four paper-` +
      `immutable contracts.\n`
  );
}

main();
