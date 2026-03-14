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
const upstreamRepoPath = path.join(root, ".cursor", "openclaw");
const upstreamTag = "v2026.3.13";
const upstreamTagObject = "61cd3a6e446c3d181a0a75861fd85d459c068a3d";
const upstreamCommit = "f6e5b6758e74608f825218de264c96b224fe2e81";
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
      `Failed to read ${upstreamTag} protocol snapshot (${upstreamCommit}) from ${upstreamRepoPath}: ${detail}`,
    );
  }
}

const body = await readUpstreamSnapshot();
await fs.writeFile(outPath, body);
console.log(
  `Synced ${outPath} from OpenClaw ${upstreamTag} (tag ${upstreamTagObject}, commit ${upstreamCommit})`,
);
