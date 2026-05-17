// SPDX-License-Identifier: MIT
//
// bytecode_no_selfdestruct.ts — Phase 8 SELFDESTRUCT bytecode gate
// ================================================================
//
// Solhint cannot block the EVM `SELFDESTRUCT` opcode (it only flags the
// deprecated `suicide` Solidity keyword via `avoid-suicide`). The paper
// §3.1 immutability claim and the FINAL_REPORT M3 finding both require an
// authoritative bytecode-level check. This script provides it.
//
// It scans the DEPLOYED bytecode of every contract that ships in M²:
//
//   - M2Token            (immutable, paper-mandated)
//   - M2Treasury         (immutable, paper-mandated)
//   - M2RevenueRouter    (immutable, paper-mandated)
//   - M2V4Hook           (immutable, paper-mandated)
//   - M2GenesisFactory   (one-shot deployer; if it could self-destruct it
//                         would destabilize CREATE2-address reproducibility)
//
// for the SELFDESTRUCT opcode `0xff`. A naive byte scan would flag
// `0xff` bytes that appear inside `PUSHN` operand windows, so we walk the
// bytecode opcode-by-opcode and skip `PUSH1..PUSH32` operand ranges,
// flagging `0xff` only when it appears as an executable opcode.
//
// Exit code is nonzero if ANY contract has a real `SELFDESTRUCT` opcode in
// its deployed bytecode. Run via: `npm run audit:bytecode`.

import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { Hex } from "viem";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CONTRACTS_ROOT = resolve(__dirname, "..", "..");

interface Target {
  /** Human-readable label used in the report. */
  label: string;
  /** Path to the Hardhat artifact JSON. */
  artifactPath: string;
  /** Whether this contract is one of the four paper-immutable contracts. */
  paperImmutable: boolean;
}

const TARGETS: readonly Target[] = [
  {
    label: "M2Token",
    artifactPath: resolve(
      CONTRACTS_ROOT,
      "artifacts/contracts/token/M2Token.sol/M2Token.json"
    ),
    paperImmutable: true,
  },
  {
    label: "M2Treasury",
    artifactPath: resolve(
      CONTRACTS_ROOT,
      "artifacts/contracts/treasury/M2Treasury.sol/M2Treasury.json"
    ),
    paperImmutable: true,
  },
  {
    label: "M2RevenueRouter",
    artifactPath: resolve(
      CONTRACTS_ROOT,
      "artifacts/contracts/router/M2RevenueRouter.sol/M2RevenueRouter.json"
    ),
    paperImmutable: true,
  },
  {
    label: "M2V4Hook",
    artifactPath: resolve(
      CONTRACTS_ROOT,
      "artifacts/contracts/hook/M2V4Hook.sol/M2V4Hook.json"
    ),
    paperImmutable: true,
  },
  {
    label: "M2GenesisFactory",
    artifactPath: resolve(
      CONTRACTS_ROOT,
      "artifacts/contracts/genesis/M2GenesisFactory.sol/M2GenesisFactory.json"
    ),
    paperImmutable: false,
  },
];

// ---------------------------------------------------------------------------
// Opcode constants
// ---------------------------------------------------------------------------

const SELFDESTRUCT = 0xff;
const PUSH1 = 0x60;
const PUSH32 = 0x7f;
// Solidity 0.8.x emits metadata-bearing constructor returns. The
// CBOR metadata trailer at the end of `bytecode` (creation code) and of
// `deployedBytecode` (runtime code) is a separate, non-executable region;
// we report findings inside it separately rather than failing on them.
// Most M² artifacts encode metadata with the `a2 64 69 70 66 73 ...`
// prefix per https://docs.soliditylang.org/en/v0.8.34/metadata.html.

// ---------------------------------------------------------------------------
// Disassembly
// ---------------------------------------------------------------------------

interface ScanResult {
  /** Offsets (decimal) within the bytecode where a real SELFDESTRUCT
   *  opcode appears as an executable instruction (i.e. NOT inside a
   *  `PUSHN` operand window and NOT inside the CBOR metadata trailer). */
  selfdestructOffsets: number[];
  /** Total executable opcodes scanned (debug / sanity). */
  opcodeCount: number;
  /** Total bytes scanned (including PUSH operands). */
  byteCount: number;
  /** Whether a metadata trailer was detected and skipped. */
  metadataDetected: boolean;
}

/**
 * Locates the Solidity CBOR metadata trailer length, if present. The last
 * two bytes of the deployed bytecode encode the length of the CBOR-encoded
 * metadata block (big-endian uint16). We detect it conservatively: only
 * trust the trailer if the implied metadata block starts with the standard
 * `0xa2 0x64` CBOR prefix used by solc 0.8.x.
 */
function detectMetadataLength(bytes: Uint8Array): number {
  if (bytes.length < 4) return 0;
  const len = (bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1];
  // Length must fit within the bytecode and leave room for opcode body.
  if (len <= 0 || len + 2 > bytes.length) return 0;
  const start = bytes.length - 2 - len;
  // CBOR map(2) tag + first key "ipfs" or "bzzr0" / "bzzr1".
  if (bytes[start] !== 0xa2 && bytes[start] !== 0xa1 && bytes[start] !== 0xa3) {
    return 0;
  }
  return len + 2; // include the trailing length prefix
}

/**
 * Walks `bytecode` (a 0x-prefixed hex string) opcode-by-opcode. PUSHN
 * operands are skipped. Records any offset whose executable byte is
 * `SELFDESTRUCT (0xff)`.
 *
 * NOTE: This is a structural disassembler — it does not follow JUMPs or
 * compute basic blocks. That's fine for the question "does the executable
 * opcode stream contain a SELFDESTRUCT" — Solidity's code layout linearly
 * concatenates all functions, so any reachable selfdestruct must appear
 * in the linear stream.
 */
function scanBytecode(bytecode: Hex): ScanResult {
  const hex = bytecode.startsWith("0x") ? bytecode.slice(2) : bytecode;
  if (hex.length === 0) {
    return { selfdestructOffsets: [], opcodeCount: 0, byteCount: 0, metadataDetected: false };
  }
  if (hex.length % 2 !== 0) {
    throw new Error(`bytecode hex has odd length: ${hex.length}`);
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }

  const metadataLen = detectMetadataLength(bytes);
  const execLen = bytes.length - metadataLen;

  const result: ScanResult = {
    selfdestructOffsets: [],
    opcodeCount: 0,
    byteCount: bytes.length,
    metadataDetected: metadataLen > 0,
  };

  let i = 0;
  while (i < execLen) {
    const op = bytes[i];
    result.opcodeCount += 1;
    if (op === SELFDESTRUCT) {
      result.selfdestructOffsets.push(i);
      i += 1;
      continue;
    }
    if (op >= PUSH1 && op <= PUSH32) {
      const operandBytes = op - PUSH1 + 1;
      i += 1 + operandBytes;
      continue;
    }
    i += 1;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Artifact loading
// ---------------------------------------------------------------------------

interface Artifact {
  contractName?: string;
  sourceName?: string;
  bytecode?: Hex;
  deployedBytecode?: Hex;
}

function loadArtifact(path: string): Artifact {
  if (!existsSync(path)) {
    throw new Error(
      `audit:bytecode: artifact missing at ${path}. ` +
        `Run \`npm run compile\` first.`
    );
  }
  const raw = readFileSync(path, "utf8");
  return JSON.parse(raw) as Artifact;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

interface Finding {
  label: string;
  paperImmutable: boolean;
  creation: ScanResult;
  deployed: ScanResult;
  hasSelfdestruct: boolean;
}

function summarize(findings: readonly Finding[]): string {
  const lines: string[] = [];
  lines.push("Phase 8 — Bytecode SELFDESTRUCT audit");
  lines.push("=".repeat(40));
  for (const f of findings) {
    const marker = f.hasSelfdestruct ? "FAIL" : "OK";
    const flag = f.paperImmutable ? " [paper-immutable]" : "";
    lines.push(
      `  [${marker}] ${f.label}${flag}` +
        `  creation: ${f.creation.opcodeCount} ops` +
        ` / ${f.creation.byteCount} B` +
        `${f.creation.metadataDetected ? " (+metadata)" : ""}` +
        ` ; deployed: ${f.deployed.opcodeCount} ops` +
        ` / ${f.deployed.byteCount} B` +
        `${f.deployed.metadataDetected ? " (+metadata)" : ""}`
    );
    if (f.creation.selfdestructOffsets.length > 0) {
      lines.push(
        `     creation-bytecode SELFDESTRUCT @ ` +
          f.creation.selfdestructOffsets.map((n) => `0x${n.toString(16)}`).join(", ")
      );
    }
    if (f.deployed.selfdestructOffsets.length > 0) {
      lines.push(
        `     deployed-bytecode SELFDESTRUCT @ ` +
          f.deployed.selfdestructOffsets.map((n) => `0x${n.toString(16)}`).join(", ")
      );
    }
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function main(): void {
  const findings: Finding[] = [];

  for (const target of TARGETS) {
    const artifact = loadArtifact(target.artifactPath);
    const creationHex = (artifact.bytecode ?? "0x") as Hex;
    const deployedHex = (artifact.deployedBytecode ?? "0x") as Hex;
    const creation = scanBytecode(creationHex);
    const deployed = scanBytecode(deployedHex);
    findings.push({
      label: target.label,
      paperImmutable: target.paperImmutable,
      creation,
      deployed,
      // Authoritative check is the DEPLOYED bytecode — that is what
      // executes at the runtime address. Creation bytecode is also
      // reported but does not by itself violate the immutability claim
      // (constructor code runs once and is then discarded).
      hasSelfdestruct: deployed.selfdestructOffsets.length > 0,
    });
  }

  const report = summarize(findings);
  process.stdout.write(`${report}\n`);

  const failures = findings.filter((f) => f.hasSelfdestruct);
  if (failures.length > 0) {
    process.stderr.write(
      `\naudit:bytecode FAILED — SELFDESTRUCT opcode in deployed bytecode of: ` +
        `${failures.map((f) => f.label).join(", ")}\n`
    );
    process.exit(1);
  }

  process.stdout.write(
    `\naudit:bytecode OK — no SELFDESTRUCT opcode in any deployed bytecode.\n`
  );
}

main();
