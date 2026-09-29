# MCP, Skills and Memory

Give the embedded agent tools from MCP servers, skills and a memory corpus.

## Overview

The embedded runtime (`EmbeddedAgentRuntime`) runs a tool-calling loop over model
contract v2. Tools come from several sources, all registered in the runtime's
`AgentToolRegistry`:

- the core tool catalog (61 upstream tool ids; which ones the Swift runtime provides is in
  `CoreToolCatalog.definition(for:).availability`),
- MCP servers (`OpenClawMCP`), exposed as `<server>__<tool>`,
- skills (`OpenClawSkills`), listed in the system prompt and read on demand,
- memory tools (`OpenClawMemory`): `memory_search`, `memory_get` and, on Apple 27, an
  opt-in `spotlight_search`,
- plugins (`OpenClawPlugins`) and your own `AgentTool` types.

With 12 or more policy-visible tools, Tool Search moves tools that are not direct-only
behind `tool_search`, `tool_describe` and `tool_call` (disable it with
`ToolSearchConfiguration(enabled: false)`).

## MCP servers

`OpenClawMCP` is a Model Context Protocol client for all platforms. `OpenClawKit`
re-exports it. Servers are configured under `mcp.servers` in `openclaw.json`:

```json
{
  "mcp": {
    "servers": {
      "docs": { "url": "https://mcp.example.com/mcp", "auth": "oauth" },
      "files": { "command": "/usr/local/bin/mcp-files", "args": ["--root", "/srv/docs"] }
    }
  }
}
```

- Transports: Streamable HTTP, legacy SSE, and stdio (macOS and Linux only). Stdio
  commands must match an `ExecCommandAllowlist` entry unless `allowUnlistedStdioCommands`
  is set.
- Tool filters, output-schema enforcement and upstream's 1,200-character description cap
  apply to every server.
- HTTP OAuth (`auth: "oauth"`): discovery, dynamic client registration or client
  metadata documents, PKCE S256 and refresh, tokens in the Keychain
  (`CredentialMCPOAuthStateStore`). On iOS, macOS and visionOS,
  `WebAuthenticationMCPOAuthPresenter` (or `MCPOAuthClient.appleDefault(...)`) uses
  `ASWebAuthenticationSession`, which needs a custom-scheme `redirectUrl`; loopback
  redirects need `ManualMCPOAuthPresenter`. The in-process gateway serves `mcp.authLogin`
  through `registerMCPOAuthGatewayMethods(on:clients:)`.

```swift
let mcpConfig = try MCPConfig.resolve(from: document)          // from OpenClawConfigDocument
let manager = MCPClientManager(config: mcpConfig)
let registered = await runtime.registerMCPTools(from: manager)
```

## Skills

Skills are `SKILL.md` folders with YAML-subset frontmatter and JSON5 metadata
(`requires`, `install`, `os`, command dispatch, display name). `SkillRegistry` loads them
with upstream source precedence (extra, plugin, bundled, custodian, workshop, managed,
personal and project agents, workspace) and evaluates eligibility.

- Prompt catalog: `SkillPromptMode.catalog` lists skills in the v6 `<available_skills>`
  format and needs a read tool; `SkillReadTool` reads skill files through
  `SkillRegistry.readAccess()`, which jails paths to the skill roots.
- Gateway methods: `registerSkillsGatewayMethods(on:configuration:)` serves
  `skills.status`, `skills.bins` and `commands.list`;
  `registerClawHubGatewayMethods(on:client:)` serves `skills.search` and `skills.detail`
  through the ClawHub client. ClawHub install and download are not implemented.
- JS and WASM skills still run through the skill executors and the exec allowlist.

## Memory

The builtin memory engine indexes `MEMORY.md`, `memory/**` and configured extra paths:

```swift
let engine = MemoryEngine(workspaceRoot: workspace)
let installation = await runtime.installMemory(engine: engine)
```

- Ranking: BM25 plus optional embeddings (OpenAI-compatible, NaturalLanguage, or any
  `ClosureMemoryEmbeddingProvider`, for example backed by `CoreAIEmbeddingProvider`),
  recency decay and MMR.
- Defaults (`MemoryEngineConfiguration`): 6 results, minimum score 0.35, vector/text
  weights 0.7/0.3, 30-day half-life.
- `installMemory` registers `memory_search` and `memory_get`, adds the Memory Recall
  prompt section, and can register `spotlight_search`. `registerMemoryGatewayMethods(on:configuration:)`
  serves `memory.search`.
- `MemoryIndex` scores are normalized BM25; retune thresholds that relied on the old
  overlap score.

### Spotlight (Apple 27)

`SpotlightMemoryIndex` mirrors memory chunks into CoreSpotlight, and
`SpotlightSearchAgentTool` wraps FoundationModels' `SpotlightSearchTool` as the
`spotlight_search` agent tool (Apple silicon only, opt-in, privacy-sensitive). Pass the
same `SpotlightMemoryIndexDelegate` to `installMemory(spotlightIndexDelegate:)` and to
`FoundationModelsSpotlightSearchOptions(searchableIndexDelegate:)`. Queries race a
3-second non-joining timeout and fall back to the in-memory mirror, so a stalled system
service cannot hang a run.

## Plugins, hooks and automations

- Plugin API v2: plugins register tools, hooks, gateway methods, MCP servers, context
  engines, memory embeddings, skill roots and services, described by
  `openclaw.plugin.json` manifests. `registerPluginGatewayMethods(on:registry:)` serves
  `plugins.list`, `plugins.setEnabled` and `hooks.status`. OpenClawKit does not run the
  upstream TypeScript plugin runtime.
- Hooks: `HookRegistry` knows the 42 upstream hook names with typed payloads, priority
  ordering and fail-closed/terminal semantics. The agent loop emits them across its
  lifecycle (`before_agent_run`, `before_tool_call`, `after_tool_call`,
  `message_sending`, compaction, session and sub-agent events, …).
- Automations: `CronScheduler` runs `at`, `every` and timezone-aware `cron` schedules
  with `systemEvent` or `agentTurn` payloads; `installAutomations(scheduler:)` adds the
  `automations` tool and `registerCronGatewayMethods(on:scheduler:)` the `cron.*` methods.

## Configuring the runtime from openclaw.json

`AgentRuntimeSettings(document:agentID:)` resolves tool policy, loop detection, Tool
Search, compaction, sub-agents, the context engine slot, session key format, MCP, skills,
memory search and catalog refresh from an `OpenClawConfigDocument`. Resolve `${VAR}`
templates first (`resolvedForRuntime(environment:)`), then apply the settings:

```swift
let loaded = try await OpenClawSDK.shared.loadConfigRuntime(fromOpenClawJSON: configURL)
let settings = AgentRuntimeSettings(document: loaded.runtimeDocument, agentID: "main")
try await runtime.apply(settings)
```
