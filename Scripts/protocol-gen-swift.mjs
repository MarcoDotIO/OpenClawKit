#!/usr/bin/env node
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const outPath = path.join(root, "Sources", "OpenClawProtocol", "GatewayModels.swift");
const upstreamRepoPath = path.join(root, ".codex", "openclaw");
const upstreamLabel = "OpenClaw 2026.4.25";
const upstreamCommit = "6b0c72bec8";
const upstreamSourcePath = path.posix.join(
  "apps",
  "shared",
  "OpenClawKit",
  "Sources",
  "OpenClawProtocol",
  "GatewayModels.swift",
);

async function readUpstreamSnapshot() {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["-C", upstreamRepoPath, "show", `${upstreamCommit}:${upstreamSourcePath}`],
      {
        cwd: root,
        maxBuffer: 16 * 1024 * 1024,
      },
    );
    return stdout;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Failed to read ${upstreamLabel} protocol snapshot (${upstreamCommit}) from ${upstreamRepoPath}: ${detail}`,
    );
  }
}

const upstreamBody = await readUpstreamSnapshot();
const body = upstreamBody.replace(
  "// swiftlint:disable file_length",
  "// swiftlint:disable file_length missing_docs",
);
await fs.writeFile(outPath, body);
console.log(
  `Synced ${outPath} from ${upstreamLabel} (${upstreamCommit})`,
);
