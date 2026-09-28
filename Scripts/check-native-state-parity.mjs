#!/usr/bin/env node
// Guards OpenClawNativeState against schema drift from the pinned upstream OpenClaw checkout.
//
// Usage:
//   node Scripts/check-native-state-parity.mjs     # exit 1 on drift; exit 0 ("skipped") without upstream
//
// Environment:
//   OPENCLAW_UPSTREAM_DIR   upstream OpenClaw git checkout (default: <repo>/.codex/openclaw)
//
// Checks (modeled on upstream scripts/check-native-state-schema-version.mjs):
//   1. `maximumSupportedSchemaVersion` in OpenClawNativeStateSQLite.swift equals upstream
//      `OPENCLAW_STATE_SCHEMA_VERSION` (src/state/openclaw-state-db-contract.ts).
//   2. The canonical DDL the SDK may create (device_identities, device_auth_tokens,
//      exec_approvals_config, macos_port_guardian_records) matches src/state/openclaw-state-schema.sql
//      after whitespace normalization, including every index upstream declares on those tables.
//   3. Informational: the upstream sessions/transcripts schema baseline hash. A change is a warning
//      (not a failure) because it signals DDL churn that may affect gateway `sessions.*` payloads.
//
// Upstream files are read with `git show <pinned commit>:<path>`; when that revision is not
// reachable the working-tree files are used instead (with a warning).
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const upstreamRepoPath = path.resolve(process.env.OPENCLAW_UPSTREAM_DIR ?? path.join(root, ".codex", "openclaw"));

const upstreamLabel = "OpenClaw 2026.9.6";
const upstreamCommit = "eb377ac59e6c9fd6c7705028034812becf00271b";
const recordedSessionBaselineHash = "917ba654c57e45fff7e225d90711c6ef395618cf3d1e980ad5138fa3abae6b71";

const swiftContractPath = path.join(root, "Sources", "OpenClawNativeState", "OpenClawNativeStateSQLite.swift");
const upstreamPaths = {
  contract: "src/state/openclaw-state-db-contract.ts",
  schema: "src/state/openclaw-state-schema.sql",
  sessionBaseline: "docs/.generated/sqlite-session-transcript-schema-baseline.sha256",
};
const canonicalTables = [
  "device_identities",
  "device_auth_tokens",
  "exec_approvals_config",
  "macos_port_guardian_records",
];

async function pathExists(candidate) {
  try {
    await fs.access(candidate);
    return true;
  } catch {
    return false;
  }
}

let usedWorkingTree = false;

async function readUpstream(relativePath) {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["-C", upstreamRepoPath, "show", `${upstreamCommit}:${relativePath}`],
      { maxBuffer: 64 * 1024 * 1024 },
    );
    return stdout;
  } catch {
    usedWorkingTree = true;
    return fs.readFile(path.join(upstreamRepoPath, relativePath), "utf8");
  }
}

function extractSingle(source, pattern, label) {
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one ${label} declaration; found ${matches.length}`);
  }
  return matches[0][1];
}

function normalizeSQL(sql) {
  return sql.replace(/\s+/gu, " ").replace(/\s*;\s*/gu, ";").trim();
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function swiftCreateSQLByTable(swiftSource) {
  const blocks = new Map();
  for (const match of swiftSource.matchAll(/createSQL: """\n([\s\S]*?)\n\s*"""/gu)) {
    const table = /CREATE TABLE IF NOT EXISTS (\w+)/u.exec(match[1])?.[1];
    if (!table) {
      throw new Error("Swift createSQL block without a CREATE TABLE statement");
    }
    if (blocks.has(table)) {
      throw new Error(`Duplicate Swift createSQL block for ${table}`);
    }
    blocks.set(table, normalizeSQL(match[1]));
  }
  return blocks;
}

function upstreamCreateSQL(schemaSource, table) {
  const name = escapeRegExp(table);
  const tableMatches = [...schemaSource.matchAll(new RegExp(`CREATE TABLE IF NOT EXISTS ${name} \\([\\s\\S]*?\\) STRICT;`, "gu"))];
  if (tableMatches.length !== 1) {
    throw new Error(`Expected exactly one upstream CREATE TABLE for ${table}; found ${tableMatches.length}`);
  }
  const indexes = [
    ...schemaSource.matchAll(new RegExp(`CREATE (?:UNIQUE )?INDEX IF NOT EXISTS \\w+\\s+ON ${name}\\s*\\([^;]*\\);`, "gu")),
  ].map((match) => match[0]);
  return normalizeSQL([tableMatches[0][0], ...indexes].join("\n"));
}

async function main() {
  if (!(await pathExists(upstreamRepoPath))) {
    console.log(`native state parity check skipped: upstream checkout not found at ${upstreamRepoPath}`);
    return;
  }

  const failures = [];
  const swiftSource = await fs.readFile(swiftContractPath, "utf8");
  const [contractSource, schemaSource] = await Promise.all([
    readUpstream(upstreamPaths.contract),
    readUpstream(upstreamPaths.schema),
  ]);

  const swiftVersion = Number(extractSingle(
    swiftSource,
    /^\s*private static let maximumSupportedSchemaVersion: Int64 = (\d+)\s*$/gmu,
    "Swift maximumSupportedSchemaVersion",
  ));
  const upstreamVersion = Number(extractSingle(
    contractSource,
    /^export const OPENCLAW_STATE_SCHEMA_VERSION = (\d+);\s*$/gmu,
    "TypeScript OPENCLAW_STATE_SCHEMA_VERSION",
  ));
  if (swiftVersion !== upstreamVersion) {
    failures.push(`schema version drift: Swift supports ${swiftVersion}, upstream owns ${upstreamVersion}`);
  }

  const swiftBlocks = swiftCreateSQLByTable(swiftSource);
  for (const table of canonicalTables) {
    const swiftSQL = swiftBlocks.get(table);
    if (!swiftSQL) {
      failures.push(`Swift canonical DDL missing for ${table}`);
      continue;
    }
    const upstreamSQL = upstreamCreateSQL(schemaSource, table);
    if (swiftSQL !== upstreamSQL) {
      failures.push(`canonical DDL drift for ${table}:\n  swift:    ${swiftSQL}\n  upstream: ${upstreamSQL}`);
    }
  }
  for (const table of swiftBlocks.keys()) {
    if (!canonicalTables.includes(table)) {
      failures.push(`Swift declares non-canonical table ${table}; add it to this guard`);
    }
  }

  try {
    const baseline = (await readUpstream(upstreamPaths.sessionBaseline)).trim().split(/\s+/u)[0];
    if (baseline !== recordedSessionBaselineHash) {
      console.warn(
        `warning: upstream sessions/transcripts schema baseline changed (${baseline}); ` +
          "review gateway sessions.* payload parity and update the recorded hash.",
      );
    }
  } catch {
    console.warn("warning: upstream sessions/transcripts schema baseline not found");
  }

  if (usedWorkingTree) {
    console.warn(`warning: ${upstreamCommit} is not reachable in ${upstreamRepoPath}; compared working-tree files`);
  }
  if (failures.length > 0) {
    for (const failure of failures) {
      console.error(failure);
    }
    process.exitCode = 1;
    return;
  }
  console.log(`native state parity check passed against ${upstreamLabel} (schema v${swiftVersion}, ${canonicalTables.length} tables)`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
