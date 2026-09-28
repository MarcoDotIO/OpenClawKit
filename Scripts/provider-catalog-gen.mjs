#!/usr/bin/env node
// Generates Sources/OpenClawModels/ProviderCatalogData.swift from the pinned upstream OpenClaw checkout.
//
// Usage:
//   node Scripts/provider-catalog-gen.mjs            # rewrite the generated catalog
//   node Scripts/provider-catalog-gen.mjs --check    # exit 1 when the generated file is stale
//   node Scripts/provider-catalog-gen.mjs --check --allow-missing-upstream
//                                                   # skip (exit 0) when the checkout is absent
//
// Environment:
//   OPENCLAW_UPSTREAM_DIR   upstream OpenClaw git checkout (default: <repo>/.codex/openclaw)
//
// Inputs:
//   - extensions/*/openclaw.plugin.json at the pinned commit: modelCatalog (providers, aliases, suppressions,
//     discovery), setup.providers[].envVars, providerAuthChoices[].method, providerAuthAliases, contracts,
//     modelIdNormalization, modelSupport.modelPrefixes, providerUsageAuthEnvVars, mediaUnderstandingProviderMetadata.
//   - extensions/*/package.json (openclaw.build.bundledDist === false marks official external packages).
//   - docs/** file list (docs paths).
//   - Scripts/provider-catalog-overrides.json: display names, default auth modes, TypeScript-defined catalogs,
//     SDK-local entries and legacy aliases.
//
// Output: one Swift file that embeds the normalized catalog document as a JSON string literal. The SDK decodes it
// lazily (OpenClawReferenceProviderCatalog). Generated Swift is used instead of a Bundle.module JSON resource so the
// OpenClawModels target needs no resources (no Package.swift change, no bundle lookup on Linux or in static links).
//
// Upstream files are read with `git show <commit>:<path>`, so the checkout may sit on any revision as long as the
// pinned commit is reachable.
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const outFile = path.join(root, "Sources", "OpenClawModels", "ProviderCatalogData.swift");
const overridesFile = path.join(here, "provider-catalog-overrides.json");
const upstreamRepoPath = path.resolve(process.env.OPENCLAW_UPSTREAM_DIR ?? path.join(root, ".codex", "openclaw"));
const checkMode = process.argv.includes("--check");
const allowMissingUpstream = process.argv.includes("--allow-missing-upstream");

const upstreamLabel = "OpenClaw 2026.9.6";
const upstreamVersion = "2026.9.6";
const upstreamCommit = "eb377ac59e";
const upstreamCommitFull = "eb377ac59e6c9fd6c7705028034812becf00271b";
const schemaVersion = 1;

const MODEL_APIS = new Set([
  "openai-completions",
  "openai-responses",
  "openai-chatgpt-responses",
  "anthropic-messages",
  "google-generative-ai",
  "google-vertex",
  "github-copilot",
  "bedrock-converse-stream",
  "ollama",
  "pi-messages",
  "azure-openai-responses",
]);
const THINKING_FORMATS = new Set(["openai", "openrouter", "deepseek", "together", "qwen", "qwen-chat-template", "zai"]);
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
// Upstream catalog inputs are text/image/document; the SDK also accepts video/audio (Google static catalogs append video).
const MODEL_INPUTS = new Set(["text", "image", "document", "video", "audio"]);
const MODEL_STATUSES = new Set(["available", "preview", "deprecated", "disabled"]);
const DISCOVERY_MODES = new Set(["static", "refreshable", "runtime"]);
const AUTH_MODES = new Set(["api-key", "aws-sdk", "oauth", "token"]);
const MAX_CONTEXT_WINDOWS = 16;

// Manifest contract key -> SDK ProviderCapability raw value. Internal kinds (gatewayMethodDispatch, codeModeExecutors,
// migrationProviders, workerProviders, decisionProviders, agentToolResultMiddleware) are intentionally not mapped.
const CONTRACT_CAPABILITIES = {
  speechProviders: "speech",
  realtimeTranscriptionProviders: "realtime-transcription",
  realtimeVoiceProviders: "realtime-voice",
  embeddingProviders: "embedding",
  memoryEmbeddingProviders: "embedding",
  mediaUnderstandingProviders: "media-understanding",
  imageGenerationProviders: "image-generation",
  videoGenerationProviders: "video-generation",
  musicGenerationProviders: "music-generation",
  webSearchProviders: "web-search",
  webFetchProviders: "web-fetch",
  documentExtractors: "document-extractors",
  webContentExtractors: "web-content-extractors",
  transcriptSourceProviders: "transcript-source",
  usageProviders: "usage",
  tools: "tool",
};
const CAPABILITY_ORDER = [
  "text",
  "image-generation",
  "video-generation",
  "music-generation",
  "speech",
  "realtime-voice",
  "realtime-transcription",
  "media-understanding",
  "embedding",
  "web-search",
  "web-fetch",
  "document-extractors",
  "web-content-extractors",
  "transcript-source",
  "usage",
  "tool",
];

// MARK: - Upstream access

async function git(args) {
  const { stdout } = await execFileAsync("git", args, { cwd: upstreamRepoPath, maxBuffer: 64 * 1024 * 1024 });
  return stdout;
}

async function gitShow(relPath) {
  try {
    return await git(["show", `${upstreamCommit}:${relPath}`]);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to read ${relPath}@${upstreamCommit} from ${upstreamRepoPath}: ${detail}`);
  }
}

async function upstreamAvailable() {
  try {
    await fs.access(upstreamRepoPath);
    await git(["cat-file", "-e", `${upstreamCommit}^{commit}`]);
    return true;
  } catch {
    return false;
  }
}

async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

async function loadUpstream() {
  const files = (await git(["ls-tree", "-r", "--name-only", upstreamCommit, "--", "extensions", "docs"]))
    .split("\n")
    .filter(Boolean);
  const manifestPaths = files.filter((file) => /^extensions\/[^/]+\/openclaw\.plugin\.json$/.test(file)).sort();
  const packagePaths = new Set(files.filter((file) => /^extensions\/[^/]+\/package\.json$/.test(file)));
  const docs = new Set(files.filter((file) => file.startsWith("docs/")));
  const plugins = await mapLimit(manifestPaths, 16, async (manifestPath) => {
    const dir = manifestPath.split("/")[1];
    const manifest = JSON.parse(await gitShow(manifestPath));
    const packagePath = `extensions/${dir}/package.json`;
    const pkg = packagePaths.has(packagePath) ? JSON.parse(await gitShow(packagePath)) : undefined;
    return { dir, manifest, pkg };
  });
  const commitTime = Number.parseInt((await git(["show", "-s", "--format=%ct", upstreamCommit])).trim(), 10);
  return { plugins, docs, generatedAt: commitTime * 1000 };
}

// MARK: - Normalization (ports packages/model-catalog-core/src/model-catalog-normalize.ts)

const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
const optionalString = (value) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const trimmedList = (value) =>
  Array.isArray(value) ? value.flatMap((entry) => (typeof entry === "string" && entry.trim() ? [entry.trim()] : [])) : [];
const nonNegative = (value) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined);
const positive = (value) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined);
const positiveInteger = (value) => (typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined);
const lower = (value) => (typeof value === "string" ? value.trim().toLowerCase() : "");
const unique = (values) => [...new Set(values.filter(Boolean))];

function normalizeStringMap(value) {
  if (!isRecord(value)) return undefined;
  const out = {};
  for (const [rawKey, rawValue] of Object.entries(value)) {
    const key = optionalString(rawKey);
    const mapped = optionalString(rawValue);
    if (key && mapped && !["__proto__", "prototype", "constructor"].includes(key)) out[key] = mapped;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

function normalizeThinkingLevelMap(value) {
  if (!isRecord(value)) return undefined;
  const out = {};
  for (const level of THINKING_LEVELS) {
    if (value[level] === null) {
      out[level] = null;
      continue;
    }
    const mapped = optionalString(value[level]);
    if (mapped !== undefined) out[level] = mapped;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

function normalizeCost(value) {
  if (!isRecord(value)) return undefined;
  const cost = {};
  for (const field of ["input", "output", "cacheRead", "cacheWrite"]) {
    const normalized = nonNegative(value[field]);
    if (normalized !== undefined) cost[field] = normalized;
  }
  if (Array.isArray(value.tieredPricing)) {
    const tiers = [];
    for (const tier of value.tieredPricing) {
      if (!isRecord(tier) || !Array.isArray(tier.range) || tier.range.length < 1 || tier.range.length > 2) continue;
      const rates = ["input", "output", "cacheRead", "cacheWrite"].map((field) => nonNegative(tier[field]));
      const range = tier.range.map(nonNegative);
      if (rates.some((rate) => rate === undefined) || range.some((bound) => bound === undefined)) continue;
      tiers.push({ input: rates[0], output: rates[1], cacheRead: rates[2], cacheWrite: rates[3], range });
    }
    if (tiers.length > 0) cost.tieredPricing = tiers;
  }
  return Object.keys(cost).length > 0 ? cost : undefined;
}

const COMPAT_BOOLEAN_FIELDS = [
  "supportsStore",
  "supportsPromptCacheKey",
  "supportsDeveloperRole",
  "supportsReasoningEffort",
  "supportsTemperature",
  "supportsInstructions",
  "supportsUsageInStreaming",
  "supportsTools",
  "supportsStrictMode",
  "supportsJsonSchemaResponseFormat",
  "requiresStringContent",
  "strictMessageKeys",
  "requiresToolResultName",
  "requiresAssistantAfterToolResult",
  "requiresThinkingAsText",
  "requiresReasoningContentOnAssistantMessages",
  "zaiToolStream",
  "sendSessionAffinityHeaders",
  "sendSessionIdHeader",
  "supportsEagerToolInputStreaming",
  "supportsLongCacheRetention",
  "supportsResponsesContinuation",
  "requiresOpenAiAnthropicToolPayload",
];

function normalizeCompat(value) {
  if (!isRecord(value)) return undefined;
  const compat = {};
  for (const field of COMPAT_BOOLEAN_FIELDS) {
    if (typeof value[field] === "boolean") compat[field] = value[field];
  }
  for (const field of ["toolSchemaProfile", "toolCallArgumentsEncoding"]) {
    const normalized = optionalString(value[field]);
    if (normalized) compat[field] = normalized;
  }
  for (const field of ["visibleReasoningDetailTypes", "supportedReasoningEfforts", "unsupportedToolSchemaKeywords"]) {
    const normalized = trimmedList(value[field]);
    if (normalized.length > 0 || (field === "supportedReasoningEfforts" && Array.isArray(value[field]))) {
      compat[field] = normalized;
    }
  }
  if (isRecord(value.reasoningEffortMap)) {
    const map = {};
    for (const [rawKey, rawMapped] of Object.entries(value.reasoningEffortMap)) {
      const key = rawKey.trim();
      const mapped = typeof rawMapped === "string" ? rawMapped.trim() : "";
      if (key && mapped) map[key] = mapped;
    }
    if (Object.keys(map).length > 0) compat.reasoningEffortMap = map;
  }
  if (value.codeMode === "preferred" || value.codeMode === "capable") compat.codeMode = value.codeMode;
  if (value.maxTokensField === "max_completion_tokens" || value.maxTokensField === "max_tokens") {
    compat.maxTokensField = value.maxTokensField;
  }
  if (THINKING_FORMATS.has(value.thinkingFormat)) compat.thinkingFormat = value.thinkingFormat;
  if (value.cacheControlFormat === "anthropic") compat.cacheControlFormat = "anthropic";
  if (isRecord(value.openRouterRouting) && Object.keys(value.openRouterRouting).length > 0) {
    compat.openRouterRouting = value.openRouterRouting;
  }
  if (isRecord(value.vercelGatewayRouting)) {
    const routing = {};
    for (const field of ["only", "order"]) {
      const list = trimmedList(value.vercelGatewayRouting[field]);
      if (list.length > 0) routing[field] = list;
    }
    if (Object.keys(routing).length > 0) compat.vercelGatewayRouting = routing;
  }
  return Object.keys(compat).length > 0 ? compat : undefined;
}

function normalizeMediaInput(value) {
  if (!isRecord(value) || !isRecord(value.image)) return undefined;
  const image = {};
  for (const field of ["maxBytes", "maxPixels", "maxSidePx", "preferredSidePx"]) {
    const normalized = positiveInteger(value.image[field]);
    if (normalized !== undefined) image[field] = normalized;
  }
  if (["tile", "detail", "provider"].includes(value.image.tokenMode)) image.tokenMode = value.image.tokenMode;
  return Object.keys(image).length > 0 ? { image } : undefined;
}

function normalizeContextWindowSelection(value) {
  if (!Array.isArray(value.contextWindows)) return {};
  const seen = new Set();
  const options = value.contextWindows.slice(0, MAX_CONTEXT_WINDOWS).flatMap((entry) => {
    if (!isRecord(entry)) return [];
    const id = optionalString(entry.id);
    const label = optionalString(entry.label);
    const contextWindow = positiveInteger(entry.contextWindow);
    if (!id || !label || contextWindow === undefined || seen.has(id)) return [];
    seen.add(id);
    return [{ id, label, contextWindow }];
  });
  options.sort((a, b) => a.contextWindow - b.contextWindow || a.id.localeCompare(b.id));
  const contextWindowDefault = optionalString(value.contextWindowDefault);
  // Options and default are one atomic tuple (upstream normalizeModelCatalogContextWindowSelection).
  if (options.length === 0 || !contextWindowDefault || !options.some((option) => option.id === contextWindowDefault)) {
    return {};
  }
  return { contextWindows: options, contextWindowDefault };
}

function normalizeModel(value) {
  if (!isRecord(value)) return undefined;
  const id = optionalString(value.id);
  if (!id) return undefined;
  const model = { id };
  const name = optionalString(value.name);
  if (name) model.name = name;
  if (MODEL_APIS.has(value.api)) model.api = value.api;
  const baseUrl = optionalString(value.baseUrl);
  if (baseUrl) model.baseUrl = baseUrl;
  const headers = normalizeStringMap(value.headers);
  if (headers) model.headers = headers;
  const input = trimmedList(value.input).filter((entry) => MODEL_INPUTS.has(entry));
  if (input.length > 0) model.input = unique(input);
  if (typeof value.reasoning === "boolean") model.reasoning = value.reasoning;
  const contextWindow = positive(value.contextWindow);
  if (contextWindow !== undefined) model.contextWindow = contextWindow;
  Object.assign(model, normalizeContextWindowSelection(value));
  const contextTokens = positiveInteger(value.contextTokens);
  if (contextTokens !== undefined) model.contextTokens = contextTokens;
  const maxTokens = positive(value.maxTokens);
  if (maxTokens !== undefined) model.maxTokens = maxTokens;
  const thinkingLevelMap = normalizeThinkingLevelMap(value.thinkingLevelMap);
  if (thinkingLevelMap) model.thinkingLevelMap = thinkingLevelMap;
  const cost = normalizeCost(value.cost);
  if (cost) model.cost = cost;
  const compat = normalizeCompat(value.compat);
  if (compat) model.compat = compat;
  const mediaInput = normalizeMediaInput(value.mediaInput);
  if (mediaInput) model.mediaInput = mediaInput;
  if (MODEL_STATUSES.has(value.status)) model.status = value.status;
  const statusReason = optionalString(value.statusReason);
  if (statusReason) model.statusReason = statusReason;
  const replaces = trimmedList(value.replaces);
  if (replaces.length > 0) model.replaces = replaces;
  const replacedBy = optionalString(value.replacedBy);
  if (replacedBy) model.replacedBy = replacedBy;
  const tags = trimmedList(value.tags);
  if (tags.length > 0) model.tags = tags;
  return model;
}

function normalizeProviderCatalog(value, context, { allowEmpty = false } = {}) {
  if (!isRecord(value)) throw new Error(`${context}: catalog must be an object`);
  const rawModels = Array.isArray(value.models) ? value.models : [];
  const models = rawModels.map(normalizeModel).filter(Boolean);
  if (models.length !== rawModels.length) throw new Error(`${context}: invalid model rows`);
  if (models.length === 0 && !allowEmpty) throw new Error(`${context}: catalog has no models`);
  const ids = new Set();
  for (const model of models) {
    if (ids.has(model.id)) throw new Error(`${context}: duplicate model id ${model.id}`);
    ids.add(model.id);
  }
  const catalog = {};
  const baseUrl = optionalString(value.baseUrl);
  if (baseUrl) catalog.baseUrl = baseUrl;
  if (MODEL_APIS.has(value.api)) catalog.api = value.api;
  else if (value.api !== undefined) throw new Error(`${context}: unknown api ${value.api}`);
  const headers = normalizeStringMap(value.headers);
  if (headers) catalog.headers = headers;
  const defaultModel = optionalString(value.defaultModel);
  if (defaultModel) catalog.defaultModel = defaultModel;
  const defaultUtilityModel = optionalString(value.defaultUtilityModel);
  if (defaultUtilityModel) catalog.defaultUtilityModel = defaultUtilityModel;
  catalog.models = models;
  return catalog;
}

function normalizeSuppression(entry, pluginId) {
  if (!isRecord(entry)) return undefined;
  const provider = lower(entry.provider);
  const model = optionalString(entry.model);
  if (!provider || !model) return undefined;
  const out = { provider, model };
  const reason = optionalString(entry.reason);
  if (reason) out.reason = reason;
  let retirement;
  if (isRecord(entry.retirement)) {
    const replacedBy = optionalString(entry.retirement.replacedBy);
    if (entry.retirement.replacedBy === undefined || replacedBy) retirement = replacedBy ? { replacedBy } : {};
  }
  const rawWhen = isRecord(entry.when) ? entry.when : undefined;
  const baseUrlHosts = trimmedList(rawWhen?.baseUrlHosts).map((host) => host.toLowerCase());
  const providerConfigApiIn = trimmedList(rawWhen?.providerConfigApiIn).map((api) => api.toLowerCase());
  const when =
    baseUrlHosts.length > 0 || providerConfigApiIn.length > 0
      ? {
          ...(baseUrlHosts.length > 0 ? { baseUrlHosts } : {}),
          ...(providerConfigApiIn.length > 0 ? { providerConfigApiIn } : {}),
        }
      : undefined;
  // A malformed retirement scope must never broaden a persistent model repair.
  if (
    retirement &&
    entry.when !== undefined &&
    (!rawWhen ||
      !when ||
      (rawWhen.baseUrlHosts !== undefined && baseUrlHosts.length === 0) ||
      (rawWhen.providerConfigApiIn !== undefined && providerConfigApiIn.length === 0))
  ) {
    return undefined;
  }
  if (retirement) out.retirement = retirement;
  if (when) out.when = when;
  out.pluginId = pluginId;
  return out;
}

function normalizeModelIdPolicy(value) {
  if (!isRecord(value)) return undefined;
  const policy = {};
  if (isRecord(value.aliases)) {
    const aliases = {};
    for (const [rawKey, rawValue] of Object.entries(value.aliases)) {
      const key = lower(rawKey);
      const mapped = optionalString(rawValue);
      if (key && mapped) aliases[key] = mapped;
    }
    if (Object.keys(aliases).length > 0) policy.aliases = aliases;
  }
  const stripPrefixes = trimmedList(value.stripPrefixes);
  if (stripPrefixes.length > 0) policy.stripPrefixes = stripPrefixes;
  const prefixWhenBare = optionalString(value.prefixWhenBare);
  if (prefixWhenBare) policy.prefixWhenBare = prefixWhenBare;
  if (Array.isArray(value.prefixWhenBareAfterAliasStartsWith)) {
    const rules = value.prefixWhenBareAfterAliasStartsWith.flatMap((rule) =>
      isRecord(rule) && optionalString(rule.modelPrefix) && optionalString(rule.prefix)
        ? [{ modelPrefix: rule.modelPrefix.trim(), prefix: rule.prefix.trim() }]
        : [],
    );
    if (rules.length > 0) policy.prefixWhenBareAfterAliasStartsWith = rules;
  }
  return Object.keys(policy).length > 0 ? policy : undefined;
}

function mergeModelIdPolicy(base, extra) {
  if (!base) return extra;
  if (!extra) return base;
  return {
    ...base,
    ...extra,
    ...(base.aliases || extra.aliases ? { aliases: { ...base.aliases, ...extra.aliases } } : {}),
  };
}

// MARK: - Catalog assembly

function sortCapabilities(capabilities) {
  const set = new Set(capabilities);
  return CAPABILITY_ORDER.filter((capability) => set.has(capability));
}

function contractCapabilities(manifest) {
  const byId = new Map();
  for (const [key, ids] of Object.entries(manifest.contracts ?? {})) {
    const capability = CONTRACT_CAPABILITIES[key];
    if (!capability || !Array.isArray(ids)) continue;
    for (const id of ids) {
      if (typeof id !== "string" || !id.trim()) continue;
      const list = byId.get(capability) ?? [];
      list.push(id.trim());
      byId.set(capability, list);
    }
  }
  return byId;
}

function resolveDocsPath(explicit, id, docs) {
  if (explicit !== undefined) {
    if (explicit !== null && !docs.has(`docs${explicit}.md`) && !docs.has(`docs${explicit}/index.md`)) {
      throw new Error(`docsPath ${explicit} for ${id} does not exist upstream`);
    }
    return explicit;
  }
  for (const candidate of [`/providers/${id}`, `/plugins/${id}`, `/tools/${id}-search`, `/tools/${id}`]) {
    if (docs.has(`docs${candidate}.md`)) return candidate;
  }
  return undefined;
}

function buildCatalog(upstream, overrides) {
  const pluginsById = new Map(upstream.plugins.map((plugin) => [plugin.manifest.id, plugin]));
  const textIds = new Set(overrides.textProviders.map((entry) => entry.id));
  const metadataIds = new Set(overrides.metadataProviders.map((entry) => entry.id));

  const owningPlugin = (providerId) =>
    upstream.plugins.find(
      (plugin) =>
        (plugin.manifest.providers ?? []).includes(providerId) ||
        Object.hasOwn(plugin.manifest.modelCatalog?.providers ?? {}, providerId),
    );
  const manifestCatalog = (providerId) => {
    for (const plugin of upstream.plugins) {
      const catalog = plugin.manifest.modelCatalog?.providers?.[providerId];
      if (catalog) return { plugin, catalog };
    }
    return undefined;
  };
  const distributionOf = (plugin) =>
    plugin?.pkg?.openclaw?.build?.bundledDist === false ? "official-external" : "bundled";

  // Provider aliases: overrides first (richer legacy routes), then manifest aliases.
  const aliases = {};
  const addAlias = (alias, target, source) => {
    const key = lower(alias);
    if (!key || textIds.has(key)) return;
    if (!textIds.has(target.provider)) throw new Error(`alias ${key} (${source}) targets unknown provider ${target.provider}`);
    if (aliases[key]) {
      if (aliases[key].provider !== target.provider) {
        throw new Error(`alias ${key} maps to both ${aliases[key].provider} and ${target.provider}`);
      }
      return;
    }
    aliases[key] = target;
  };
  for (const [alias, target] of Object.entries(overrides.providerAliases ?? {})) {
    const entry = { provider: target.provider };
    if (target.api) entry.api = target.api;
    if (target.baseUrl) entry.baseUrl = target.baseUrl;
    if (target.auth) entry.auth = target.auth;
    if (target.runtimeHint) entry.runtimeHint = target.runtimeHint;
    if (target.legacy) entry.legacy = true;
    addAlias(alias, entry, "overrides");
  }
  for (const entry of overrides.textProviders) {
    for (const alias of entry.aliases ?? []) addAlias(alias, { provider: entry.id }, `overrides.${entry.id}`);
  }
  const authAliases = { ...(overrides.authAliases ?? {}) };
  for (const plugin of upstream.plugins) {
    for (const [alias, target] of Object.entries(plugin.manifest.modelCatalog?.aliases ?? {})) {
      if (!isRecord(target)) continue;
      const provider = lower(target.provider);
      if (!textIds.has(provider)) continue;
      const entry = { provider };
      if (MODEL_APIS.has(target.api)) entry.api = target.api;
      if (optionalString(target.baseUrl)) entry.baseUrl = target.baseUrl.trim();
      addAlias(alias, entry, `${plugin.manifest.id}.modelCatalog.aliases`);
    }
    for (const [alias, target] of Object.entries(plugin.manifest.providerAuthAliases ?? {})) {
      // Conditional auth aliases (object form with baseUrls, e.g. arcee -> openrouter) stay runtime-only.
      if (typeof target !== "string") continue;
      const provider = lower(target);
      const key = lower(alias);
      if (textIds.has(key)) {
        authAliases[key] = provider;
      } else if (textIds.has(provider)) {
        addAlias(key, { provider }, `${plugin.manifest.id}.providerAuthAliases`);
      }
    }
  }
  // Extra ids listed in a plugin's `providers` array alias the plugin's first catalog text provider.
  for (const plugin of upstream.plugins) {
    const owned = (plugin.manifest.providers ?? []).map(lower);
    const primary = owned.find((id) => textIds.has(id));
    if (!primary) continue;
    for (const id of owned) {
      if (!textIds.has(id) && !metadataIds.has(id) && !aliases[id]) addAlias(id, { provider: primary }, `${plugin.manifest.id}.providers`);
    }
  }

  const aliasesByProvider = new Map();
  for (const [alias, target] of Object.entries(aliases)) {
    const list = aliasesByProvider.get(target.provider) ?? [];
    list.push(alias);
    aliasesByProvider.set(target.provider, list);
  }

  // Capability contract ids per plugin, assigned to text providers of that plugin.
  const capabilityProviders = {};
  const recordCapabilityProvider = (capability, id) => {
    const list = capabilityProviders[capability] ?? [];
    if (!list.includes(id)) list.push(id);
    capabilityProviders[capability] = list;
  };

  const rawCatalogs = new Map();
  const providers = overrides.textProviders.map((override) => {
    const context = `textProviders.${override.id}`;
    let found = manifestCatalog(override.id);
    const plugin = override.pluginId ? pluginsById.get(override.pluginId) : (found?.plugin ?? owningPlugin(override.id));
    if (override.pluginId && !plugin) throw new Error(`${context}: unknown plugin ${override.pluginId}`);
    if (!plugin && !override.sdkLocal) throw new Error(`${context}: no upstream plugin owns this provider (mark sdkLocal)`);

    let rawCatalog;
    if (override.catalog) {
      if (found) throw new Error(`${context}: upstream now ships a manifest catalog; drop the overrides catalog`);
      rawCatalog = override.catalog;
    } else if (override.catalogFrom) {
      const source =
        manifestCatalog(override.catalogFrom.provider) ??
        (rawCatalogs.has(override.catalogFrom.provider) ? { catalog: rawCatalogs.get(override.catalogFrom.provider) } : undefined);
      if (!source) throw new Error(`${context}: catalogFrom ${override.catalogFrom.provider} has no catalog (list it first)`);
      const keep = override.catalogFrom.models;
      rawCatalog = {
        ...source.catalog,
        defaultModel: undefined,
        defaultUtilityModel: undefined,
        models: keep
          ? keep.map((id) => {
              const row = source.catalog.models.find((model) => model.id === id);
              if (!row) throw new Error(`${context}: catalogFrom model ${id} not found`);
              return row;
            })
          : source.catalog.models,
      };
    } else if (found) {
      rawCatalog = found.catalog;
    } else {
      throw new Error(`${context}: no manifest catalog; provide overrides catalog or catalogFrom`);
    }
    rawCatalogs.set(override.id, rawCatalog);
    const allowEmpty = override.discovery === "runtime" || plugin?.manifest.modelCatalog?.discovery?.[override.id] !== undefined;
    const catalog = normalizeProviderCatalog(rawCatalog, context, { allowEmpty: allowEmpty && (rawCatalog.models ?? []).length === 0 });
    const patch = override.catalogPatch ?? {};
    if (patch.baseUrl) catalog.baseUrl = patch.baseUrl;
    if (patch.api) {
      if (!MODEL_APIS.has(patch.api)) throw new Error(`${context}: unknown patch api ${patch.api}`);
      catalog.api = patch.api;
    }
    for (const model of catalog.models) {
      for (const field of patch.dropModelFields ?? []) delete model[field];
      if (patch.appendInput) model.input = unique([...(model.input ?? ["text"]), ...patch.appendInput]);
    }
    if (!catalog.baseUrl) throw new Error(`${context}: catalog baseUrl is required`);
    if (override.defaultModel) catalog.defaultModel = override.defaultModel;
    if (override.defaultUtilityModel) catalog.defaultUtilityModel = override.defaultUtilityModel;
    if (!catalog.defaultModel && catalog.models.length > 0) catalog.defaultModel = catalog.models[0].id;
    for (const field of ["defaultModel", "defaultUtilityModel"]) {
      if (catalog[field] && !catalog.models.some((model) => model.id === catalog[field])) {
        throw new Error(`${context}: ${field} ${catalog[field]} is not a catalog model`);
      }
    }

    const manifest = plugin?.manifest ?? {};
    const setup = (manifest.setup?.providers ?? []).filter(isRecord);
    const ownSetup = setup.find((entry) => entry.id === override.id);
    const envVars = override.envVars ?? unique(trimmedList(ownSetup?.envVars));
    const pluginTextProviders = (manifest.providers ?? []).map(lower).filter((id) => textIds.has(id));
    const primaryTextProvider = pluginTextProviders[0] ?? override.id;
    const auxiliaryEnvVars = {};
    for (const entry of setup) {
      if (primaryTextProvider !== override.id) break;
      if (entry.id !== override.id && !textIds.has(entry.id) && !metadataIds.has(entry.id) && trimmedList(entry.envVars).length > 0) {
        // Aliases of this provider inherit the provider env; only independent surfaces are recorded.
        if (aliases[lower(entry.id)]?.provider === override.id) continue;
        auxiliaryEnvVars[entry.id] = trimmedList(entry.envVars);
      }
    }
    const authMethods = unique([
      ...(manifest.providerAuthChoices ?? [])
        .filter((choice) => isRecord(choice) && lower(choice.provider) === override.id)
        .map((choice) => optionalString(choice.method)),
      ...trimmedList(ownSetup?.authMethods),
      ...(override.authMethods ?? []),
    ]);
    const usageEnvVars = trimmedList(manifest.providerUsageAuthEnvVars?.[override.id]);
    const discovery = override.discovery ?? manifest.modelCatalog?.discovery?.[override.id];
    if (discovery !== undefined && !DISCOVERY_MODES.has(discovery)) throw new Error(`${context}: bad discovery ${discovery}`);
    if (override.auth !== null && override.auth !== undefined && !AUTH_MODES.has(override.auth)) {
      throw new Error(`${context}: bad auth ${override.auth}`);
    }

    // Capabilities: every contract id owned by this provider (or foreign ids for the plugin's primary provider).
    const capabilities = ["text", ...(override.capabilities ?? [])];
    const capabilityProviderIds = {};
    if (plugin) {
      // Contract ids that name another provider of the same plugin belong to it; everything else (for example
      // google's `gemini` embedding id or moonshot's `kimi` web-search id) belongs to the plugin's primary provider.
      for (const [capability, ids] of contractCapabilities(manifest)) {
        const mine = ids.filter((id) => {
          const aliasTarget = aliases[id]?.provider;
          const target = pluginTextProviders.includes(id)
            ? id
            : aliasTarget && pluginTextProviders.includes(aliasTarget)
              ? aliasTarget
              : primaryTextProvider;
          return target === override.id;
        });
        if (mine.length === 0) continue;
        capabilities.push(capability);
        for (const id of mine) recordCapabilityProvider(capability, id);
        if (capability !== "tool" && !(mine.length === 1 && mine[0] === override.id)) capabilityProviderIds[capability] = mine;
        if (capability === "tool") capabilityProviderIds[capability] = mine;
      }
    }
    recordCapabilityProvider("text", override.id);

    const record = {
      id: override.id,
      ...(plugin ? { pluginId: plugin.manifest.id } : {}),
      displayName: override.displayName,
      aliases: aliasesByProvider.get(override.id) ?? [],
      capabilities: sortCapabilities(capabilities),
      ...(Object.keys(capabilityProviderIds).length > 0 ? { capabilityProviderIds } : {}),
      auth: override.auth ?? null,
      ...(override.authHeader !== undefined ? { authHeader: override.authHeader } : {}),
      authMethods,
      envVars,
      ...(usageEnvVars.length > 0 ? { usageEnvVars } : {}),
      ...(Object.keys(auxiliaryEnvVars).length > 0 ? { auxiliaryEnvVars } : {}),
      ...(discovery ? { discovery } : {}),
    };
    const docsPath = resolveDocsPath(override.docsPath, override.id, upstream.docs);
    if (docsPath) record.docsPath = docsPath;
    record.status = override.status ?? "available";
    if (override.statusReason) record.statusReason = override.statusReason;
    if (override.replacedBy) record.replacedBy = override.replacedBy;
    record.distribution = plugin && !override.sdkLocal ? distributionOf(plugin) : "bundled";
    if (override.sdkLocal) record.sdkLocal = true;
    record.catalog = catalog;
    return record;
  });

  const metadataProviders = overrides.metadataProviders.map((override) => {
    const context = `metadataProviders.${override.id}`;
    const plugin = override.pluginId
      ? pluginsById.get(override.pluginId)
      : (pluginsById.get(override.id) ?? owningPlugin(override.id));
    if (!plugin && !override.sdkLocal) throw new Error(`${context}: no upstream plugin`);
    const manifest = plugin?.manifest ?? {};
    const capabilities = [...(override.capabilities ?? [])];
    const ids = new Set();
    for (const [capability, contractIds] of contractCapabilities(manifest)) {
      if (capability === "tool") continue;
      capabilities.push(capability);
      for (const id of contractIds) {
        ids.add(id);
        recordCapabilityProvider(capability, id);
      }
    }
    if (capabilities.length === 0) throw new Error(`${context}: no capabilities`);
    const setup = (manifest.setup?.providers ?? []).filter(isRecord);
    const ownSetup = setup.find((entry) => entry.id === override.id) ?? setup[0];
    const authMethods = unique([
      ...(manifest.providerAuthChoices ?? []).filter(isRecord).map((choice) => optionalString(choice.method)),
      ...(override.authMethods ?? []),
    ]);
    const record = {
      id: override.id,
      ...(plugin ? { pluginId: plugin.manifest.id } : {}),
      displayName: override.displayName,
      aliases: [...ids].filter((id) => id !== override.id),
      capabilities: sortCapabilities(capabilities),
      authMethods,
      envVars: trimmedList(ownSetup?.envVars),
    };
    const docsPath = resolveDocsPath(override.docsPath, override.id, upstream.docs);
    if (docsPath) record.docsPath = docsPath;
    record.distribution = plugin ? distributionOf(plugin) : "bundled";
    if (override.sdkLocal) record.sdkLocal = true;
    record.nativeRuntimeAvailable = override.nativeRuntimeAvailable === true;
    return record;
  });

  const knownProviders = new Set([...textIds, ...Object.keys(aliases)]);
  const suppressions = [];
  const modelIdNormalization = {};
  const modelPrefixes = [];
  const mediaUnderstanding = {};
  for (const plugin of upstream.plugins) {
    const manifest = plugin.manifest;
    for (const entry of manifest.modelCatalog?.suppressions ?? []) {
      const normalized = normalizeSuppression(entry, manifest.id);
      if (normalized && knownProviders.has(normalized.provider)) suppressions.push(normalized);
    }
    for (const [provider, policy] of Object.entries(manifest.modelIdNormalization?.providers ?? {})) {
      const normalized = normalizeModelIdPolicy(policy);
      if (normalized) modelIdNormalization[lower(provider)] = mergeModelIdPolicy(modelIdNormalization[lower(provider)], normalized);
    }
    const primary = (manifest.providers ?? []).map(lower).find((id) => textIds.has(id));
    for (const prefix of trimmedList(manifest.modelSupport?.modelPrefixes)) {
      if (primary) modelPrefixes.push({ prefix, provider: primary });
    }
    for (const [provider, metadata] of Object.entries(manifest.mediaUnderstandingProviderMetadata ?? {})) {
      if (isRecord(metadata)) mediaUnderstanding[lower(provider)] = { pluginId: manifest.id, ...metadata };
    }
  }
  for (const [provider, policy] of Object.entries(overrides.modelIdNormalization ?? {})) {
    const normalized = normalizeModelIdPolicy(policy);
    if (normalized) modelIdNormalization[lower(provider)] = mergeModelIdPolicy(modelIdNormalization[lower(provider)], normalized);
  }
  const sortedObject = (object) => Object.fromEntries(Object.entries(object).sort(([a], [b]) => a.localeCompare(b)));

  const modelCount = providers.reduce((total, provider) => total + provider.catalog.models.length, 0);
  return {
    document: {
      schemaVersion,
      sourceVersion: upstreamVersion,
      sourceCommit: upstreamCommit,
      sourceCommitFull: upstreamCommitFull,
      generatedAt: upstream.generatedAt,
      providers,
      metadataProviders,
      aliases: sortedObject(aliases),
      authAliases: sortedObject(authAliases),
      suppressions,
      modelIdNormalization: sortedObject(modelIdNormalization),
      modelPrefixes,
      capabilityProviders: Object.fromEntries(
        CAPABILITY_ORDER.filter((capability) => capabilityProviders[capability]).map((capability) => [
          capability,
          capabilityProviders[capability],
        ]),
      ),
      mediaUnderstanding: sortedObject(mediaUnderstanding),
    },
    stats: {
      providers: providers.length,
      metadata: metadataProviders.length,
      models: modelCount,
      aliases: Object.keys(aliases).length,
      suppressions: suppressions.length,
    },
  };
}

// MARK: - Output

// Pretty-prints JSON, keeping any object/array whose compact form fits on one line compact.
function formatJSON(value, indent = "") {
  const compact = JSON.stringify(value);
  if (compact.length + indent.length <= 150 || value === null || typeof value !== "object") return compact;
  const inner = `${indent}  `;
  if (Array.isArray(value)) {
    return `[\n${value.map((entry) => `${inner}${formatJSON(entry, inner)}`).join(",\n")}\n${indent}]`;
  }
  const entries = Object.entries(value).map(([key, entry]) => `${inner}${JSON.stringify(key)}: ${formatJSON(entry, inner)}`);
  return `{\n${entries.join(",\n")}\n${indent}}`;
}

function renderSwift(document) {
  const json = formatJSON(document);
  if (json.includes('"""##') || json.includes("\\##")) {
    throw new Error("Catalog JSON contains a raw-string delimiter sequence; change the Swift delimiter");
  }
  JSON.parse(json);
  return `// Generated by Scripts/provider-catalog-gen.mjs from ${upstreamLabel} (${upstreamCommit}) — do not edit by hand
// swiftlint:disable line_length

/// Upstream provider catalog snapshot embedded as JSON and decoded lazily by \`\`OpenClawReferenceProviderCatalog\`\`.
///
/// Regenerate with \`node Scripts/provider-catalog-gen.mjs\` (verify with \`--check\`). Upstream inputs are the
/// \`extensions/*/openclaw.plugin.json\` manifests at the pinned commit plus \`Scripts/provider-catalog-overrides.json\`.
enum ProviderCatalogGeneratedData {
    /// Upstream OpenClaw release train the snapshot was generated from.
    static let sourceVersion = "${upstreamVersion}"
    /// Short upstream commit the snapshot was generated from.
    static let sourceCommit = "${upstreamCommit}"
    /// Catalog document schema version.
    static let schemaVersion = ${schemaVersion}
    /// Upstream commit time in milliseconds since the Unix epoch; used as the bundled catalog's \`generatedAt\`.
    static let generatedAt: Int64 = ${document.generatedAt}

    /// Normalized catalog document.
    static let json = ##"""
${json}
"""##
}
`;
}

async function main() {
  if (!(await upstreamAvailable())) {
    const message = `Upstream OpenClaw checkout with ${upstreamCommit} not found at ${upstreamRepoPath} (set OPENCLAW_UPSTREAM_DIR).`;
    if (checkMode && allowMissingUpstream) {
      console.log(`${message} Skipping provider catalog check.`);
      return;
    }
    console.error(message);
    process.exit(1);
  }
  const overrides = JSON.parse(await fs.readFile(overridesFile, "utf8"));
  const upstream = await loadUpstream();
  const { document, stats } = buildCatalog(upstream, overrides);
  const rendered = renderSwift(document);
  const summary = `providers=${stats.providers} metadata=${stats.metadata} models=${stats.models} aliases=${stats.aliases} suppressions=${stats.suppressions}`;
  if (checkMode) {
    let current = "";
    try {
      current = await fs.readFile(outFile, "utf8");
    } catch {
      current = "";
    }
    if (current !== rendered) {
      console.error(`${path.relative(root, outFile)} is stale; run node Scripts/provider-catalog-gen.mjs`);
      process.exit(1);
    }
    console.log(`Checked provider catalog from ${upstreamLabel} (${upstreamCommit}): ${summary}`);
    return;
  }
  await fs.writeFile(outFile, rendered);
  console.log(`Wrote ${path.relative(root, outFile)} from ${upstreamLabel} (${upstreamCommit}): ${summary}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
