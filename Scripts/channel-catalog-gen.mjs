#!/usr/bin/env node
// Generates the OpenClawChannels channel metadata catalog from the pinned upstream OpenClaw checkout.
//
// Usage:
//   node Scripts/channel-catalog-gen.mjs                       # rewrite the generated Swift file
//   node Scripts/channel-catalog-gen.mjs --check               # exit 1 when the generated file is stale
//   node Scripts/channel-catalog-gen.mjs --check --allow-missing-upstream
//                                                              # skip (exit 0) when the checkout is absent
//   node Scripts/channel-catalog-gen.mjs --upstream .codex/openclaw --out <file>
//
// Environment:
//   OPENCLAW_UPSTREAM_DIR   upstream OpenClaw git checkout (default: <repo>/.codex/openclaw)
//
// Inputs (read with `git show <commit>:<path>` so the checkout may sit on any revision):
//   - extensions/<id>/openclaw.plugin.json with a non-empty `channels` array, joined with that
//     extension's package.json `openclaw.channel` block and package name;
//   - scripts/lib/official-external-channel-catalog.json (official/external npm channel plugins).
//
// Distribution and removed-channel status come from the checked-in override maps below. Channel
// capabilities and format profiles stay hand-maintained in Swift
// (Sources/OpenClawChannels/ChannelCapabilities+Catalog.swift) because upstream defines them in
// TypeScript code; this script only warns when a channel id has no capabilities row there.
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

function argValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const upstreamRepoPath = path.resolve(
  root,
  argValue("--upstream") ?? process.env.OPENCLAW_UPSTREAM_DIR ?? path.join(root, ".codex", "openclaw"),
);
const outFile = path.resolve(
  root,
  argValue("--out") ?? path.join("Sources", "OpenClawChannels", "ChannelMetadataCatalog+Generated.swift"),
);
const capabilitiesFile = path.join(root, "Sources", "OpenClawChannels", "ChannelCapabilities+Catalog.swift");
const checkMode = process.argv.includes("--check");
const allowMissingUpstream = process.argv.includes("--allow-missing-upstream");

const upstreamLabel = "OpenClaw 2026.9.6";
const upstreamVersion = "2026.9.6";
const upstreamTag = "v2026.9.6";
const upstreamCommit = "eb377ac59e";

// Channels that ship inside the upstream repo and are not published as separate npm plugins.
const BUNDLED_OVERRIDES = new Set(["telegram", "a2a", "reef", "qa-channel"]);

// Rows that upstream does not (or no longer) publish through a plugin manifest.
const CHECKED_IN_ROWS = {
  webchat: {
    id: "webchat",
    label: "WebChat",
    docsPath: "/web/webchat",
    distribution: "core",
    status: "active",
  },
  bluebubbles: {
    id: "bluebubbles",
    label: "BlueBubbles",
    selectionLabel: "BlueBubbles (macOS app)",
    detailLabel: "BlueBubbles",
    docsPath: "/channels/bluebubbles",
    aliases: ["bb"],
    order: 75,
    systemImage: "bubble.left.and.text.bubble.right",
    distribution: "bundled",
    packageName: "@openclaw/bluebubbles",
    status: "removed",
  },
};

async function git(args) {
  const { stdout } = await execFileAsync("git", args, { cwd: upstreamRepoPath, maxBuffer: 64 * 1024 * 1024 });
  return stdout;
}

async function gitShowJSON(relPath) {
  try {
    return JSON.parse(await git(["show", `${upstreamCommit}:${relPath}`]));
  } catch {
    return undefined;
  }
}

function lowerTrim(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function cleanString(value) {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function rowFromChannelBlock(channel, fallbackID) {
  const id = lowerTrim(channel?.id) || fallbackID;
  const aliases = Array.isArray(channel?.aliases)
    ? [...new Set(channel.aliases.map((alias) => lowerTrim(alias)).filter((alias) => alias && alias !== id))]
    : [];
  const exposure = channel?.exposure ?? {};
  const hidden = exposure.configured === false && exposure.setup === false && exposure.docs === false;
  return {
    id,
    label: cleanString(channel?.label) ?? id,
    selectionLabel: cleanString(channel?.selectionLabel),
    detailLabel: cleanString(channel?.detailLabel),
    docsPath: cleanString(channel?.docsPath) ?? `/channels/${id}`,
    aliases,
    order: typeof channel?.order === "number" && Number.isFinite(channel.order) ? channel.order : undefined,
    systemImage: cleanString(channel?.systemImage),
    hidden,
  };
}

async function collectRows() {
  const rows = new Map();
  const listing = await git(["ls-tree", "--name-only", `${upstreamCommit}`, "extensions/"]);
  const extensionDirs = listing
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => line.replace(/^extensions\//, ""))
    .sort();

  for (const dir of extensionDirs) {
    const manifest = await gitShowJSON(`extensions/${dir}/openclaw.plugin.json`);
    const channels = Array.isArray(manifest?.channels) ? manifest.channels : [];
    if (channels.length === 0) {
      continue;
    }
    const pkg = (await gitShowJSON(`extensions/${dir}/package.json`)) ?? {};
    const channelBlock = pkg?.openclaw?.channel ?? {};
    for (const channelID of channels) {
      const id = lowerTrim(channelID);
      if (!id) continue;
      const block = lowerTrim(channelBlock.id) === id ? channelBlock : { id };
      const row = rowFromChannelBlock(block, id);
      row.packageName = cleanString(pkg.name);
      // In-repo channels default to bundled; the official catalog below upgrades published ones.
      row.distribution = "bundled";
      row.status = "active";
      row.legacyPackageNames = [];
      rows.set(id, row);
    }
  }

  const catalog = (await gitShowJSON("scripts/lib/official-external-channel-catalog.json")) ?? {};
  const entries = Array.isArray(catalog.entries) ? catalog.entries : [];
  for (const entry of entries) {
    const channel = entry?.openclaw?.channel;
    const id = lowerTrim(channel?.id);
    if (!id) continue;
    const source = lowerTrim(entry.source ?? entry?.openclaw?.source);
    const catalogRow = rowFromChannelBlock(channel, id);
    const existing = rows.get(id);
    // The bundled manifest wins for display fields; the catalog adds aliases and the npm package.
    const row = existing ? { ...catalogRow, ...stripUndefined(existing) } : catalogRow;
    row.aliases = [...new Set([...(existing?.aliases ?? []), ...catalogRow.aliases])];
    row.packageName = cleanString(entry.name) ?? existing?.packageName;
    row.legacyPackageNames = Array.isArray(entry?.openclaw?.legacyNpmPackageNames)
      ? entry.openclaw.legacyNpmPackageNames.map((name) => String(name).trim()).filter(Boolean)
      : [];
    if (BUNDLED_OVERRIDES.has(id)) {
      row.distribution = "bundled";
      row.status = "active";
    } else if (source === "external") {
      row.distribution = "external";
      row.status = "external";
    } else {
      row.distribution = "official";
      row.status = "active";
    }
    rows.set(id, row);
  }

  for (const [id, row] of Object.entries(CHECKED_IN_ROWS)) {
    if (!rows.has(id)) {
      rows.set(id, { aliases: [], legacyPackageNames: [], hidden: false, ...row });
    } else {
      rows.set(id, { ...rows.get(id), distribution: row.distribution, status: row.status });
    }
  }

  return [...rows.values()].sort((left, right) => {
    const lo = left.order ?? Number.MAX_SAFE_INTEGER;
    const ro = right.order ?? Number.MAX_SAFE_INTEGER;
    if (lo !== ro) return lo - ro;
    return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
  });
}

function stripUndefined(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));
}

function swiftString(value) {
  if (value === undefined || value === null) return "nil";
  const escaped = String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `"${escaped}"`;
}

function swiftStringArray(values) {
  if (!values || values.length === 0) return "[]";
  return `[${values.map(swiftString).join(", ")}]`;
}

function renderRow(row) {
  return [
    "        ChannelUpstreamRow(",
    `            id: ${swiftString(row.id)},`,
    `            label: ${swiftString(row.label)},`,
    `            selectionLabel: ${swiftString(row.selectionLabel)},`,
    `            detailLabel: ${swiftString(row.detailLabel)},`,
    `            docsPath: ${swiftString(row.docsPath)},`,
    `            aliases: ${swiftStringArray(row.aliases)},`,
    `            order: ${row.order === undefined ? "nil" : String(row.order)},`,
    `            systemImage: ${swiftString(row.systemImage)},`,
    `            distribution: .${row.distribution},`,
    `            packageName: ${swiftString(row.packageName)},`,
    `            legacyPackageNames: ${swiftStringArray(row.legacyPackageNames)},`,
    `            removedUpstream: ${row.status === "removed" ? "true" : "false"},`,
    `            hidden: ${row.hidden ? "true" : "false"}`,
    "        ),",
  ].join("\n");
}

function render(rows) {
  const header = [
    `// Generated by Scripts/channel-catalog-gen.mjs from ${upstreamLabel} (${upstreamCommit}) — do not edit by hand`,
    "//",
    "// Regenerate with `node Scripts/channel-catalog-gen.mjs`; CI runs `--check` to catch drift.",
    "",
    "extension OpenClawChannelMetadataCatalog {",
    "    /// Upstream OpenClaw release the channel metadata catalog was generated from.",
    `    public static let upstreamVersion = ${swiftString(upstreamVersion)}`,
    "    /// Upstream OpenClaw release tag the channel metadata catalog was generated from.",
    `    public static let upstreamTag = ${swiftString(upstreamTag)}`,
    "    /// Abbreviated upstream commit the channel metadata catalog was generated from.",
    `    public static let referenceCommit = ${swiftString(upstreamCommit)}`,
    "",
    "    /// Upstream channel rows sorted by upstream catalog order, then id.",
    "    static let generatedRows: [ChannelUpstreamRow] = [",
  ];
  const footer = ["    ]", "}", ""];
  return [...header, ...rows.map(renderRow), ...footer].join("\n");
}

async function warnMissingCapabilities(rows) {
  let source = "";
  try {
    source = await fs.readFile(capabilitiesFile, "utf8");
  } catch {
    console.warn(`warning: ${path.relative(root, capabilitiesFile)} not found; skipping capabilities coverage check`);
    return;
  }
  for (const row of rows) {
    if (!source.includes(`"${row.id}"`)) {
      console.warn(`warning: channel "${row.id}" has no capabilities row in ${path.relative(root, capabilitiesFile)}`);
    }
  }
}

async function main() {
  try {
    await execFileAsync("git", ["cat-file", "-e", `${upstreamCommit}^{commit}`], { cwd: upstreamRepoPath });
  } catch {
    if (checkMode && allowMissingUpstream) {
      console.log(`Upstream checkout ${upstreamRepoPath} (${upstreamCommit}) unavailable; skipping channel catalog check.`);
      return;
    }
    console.error(`Upstream checkout ${upstreamRepoPath} does not contain ${upstreamCommit}.`);
    process.exit(1);
  }

  const rows = await collectRows();
  await warnMissingCapabilities(rows);
  const output = render(rows);

  if (checkMode) {
    let current = "";
    try {
      current = await fs.readFile(outFile, "utf8");
    } catch {
      current = "";
    }
    if (current !== output) {
      console.error(`${path.relative(root, outFile)} is stale; run node Scripts/channel-catalog-gen.mjs`);
      process.exit(1);
    }
    console.log(`Checked ${rows.length} channel rows from ${upstreamLabel} (${upstreamCommit}).`);
    return;
  }

  await fs.writeFile(outFile, output);
  console.log(`Generated ${rows.length} channel rows from ${upstreamLabel} (${upstreamCommit}) into ${path.relative(root, outFile)}.`);
}

await main();
