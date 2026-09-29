# Provider Routing and Fast Mode

Model execution flows through `OpenClawModels`, with `OpenClawKit` re-exporting
the routing and provider types for app-level use.

## Provider Catalog

`OpenClawReferenceProviderCatalog` is generated from the upstream OpenClaw `v2026.9.6`
extension manifests by `Scripts/provider-catalog-gen.mjs`: 70 text providers with 357
manifest model rows, plus metadata-only capability providers (speech, embeddings, web
search, media understanding, image and video generation). Rows carry status and
`replacedBy`, context-window options, thinking-level maps, tiered pricing, compat flags
and media-input limits.

- Canonical ids follow upstream: `google` (alias `gemini`), `apple-fm` (alias
  `foundation`), `kimi` and `qwen`. `openai-codex/<model>` and `codex/<model>` resolve to
  `openai/<model>` on the ChatGPT OAuth route with runtime hint `codex`.
- `resolveModelRef(_:)` and `canonicalizeModelRef(_:)` migrate stored refs;
  `thinkingProfile(providerID:modelID:agentRuntime:)` and `modelChoices(...)` let pickers
  offer `max`/`ultra` and larger context windows only where a model supports them.
- Hosted catalog refresh is off by default in the SDK (upstream enables it); opt in
  with `try ModelCatalogRefreshConfiguration(isEnabled: true)` and a
  `ModelCatalogRefreshClient` with a persistence such as `.file(at:)`.

## Router Behavior

``ModelRouter`` chooses providers from the configured catalog, applies auth
resolution, and can fall back across compatible providers when one endpoint is
unavailable. `ModelProviderFactory.makeProviders(from:)` builds providers from config,
skips providers whose `api` it does not recognize, and returns a
`RoutingModelProvider` when models of one provider use different `api` or `baseUrl`
values. `ModelRouter` does not resolve provider aliases, so route with canonical ids.

Streaming fallback happens only for `generate`: a stream that fails before its first
chunk surfaces the error to the caller instead of trying the next provider.

## Model Contract v2

Every HTTP provider maps the v2 request and response contract (OpenAI Chat Completions
and Responses, the ChatGPT/Codex route, Azure, Anthropic, Gemini/Vertex, Bedrock and
native Ollama): transcript `messages`, `tools` and `toolChoice`, JSON-schema
`responseFormat`, tool calls, usage, stop reasons and reasoning. Providers only propose
tool calls; the agent loop approves and runs them. Streaming providers emit text,
reasoning, tool-call delta and usage chunks followed by a final chunk.

`ModelStreamingHTTPClient` streams incrementally with `URLSession.bytes` on Apple
platforms; on Linux the body is buffered and replayed line by line. The default request
timeout is 120 seconds (`timeoutSeconds` in the provider config overrides it).

## Thinking Levels and Reasoning Effort

`ThinkLevel` includes `max` and `ultra` (`ultra` is sent to providers as `max`), and
`none` normalizes to `off`. The runtime passes `ModelGenerationPolicy.thinkingLevel`
through, clamped to the catalog thinking profile; providers resolve their own effort
with `ReasoningEffortResolver`. Anthropic uses adaptive or budget thinking and replays
thinking signatures across tool turns; Gemini 3 thought signatures are replayed from an
in-process cache.

## Fast Mode

Fast mode (`FastMode`: `on`, `off` or `auto`) can be set per model in config and
overridden per session or request. `auto` turns fast mode on for the first
`FastMode.defaultAutoOnSeconds` (60) of a run. OpenAI gets the priority service tier
only on verified native routes, without lowering reasoning effort or verbosity;
Anthropic uses native fast mode for Opus 5 and Opus 4.8; xAI and MiniMax switch to
their fast models.

## Prompt Caching

`ModelGenerationPolicy.promptCache` enables Anthropic `cache_control` markers and OpenAI
`prompt_cache_key` and retention, plus session-affinity headers where the endpoint
supports them.

## OpenAI and Codex

The public OpenAI providers send every request through the contract-v2 Responses and
Chat Completions engines; OpenAIKit is no longer used on these paths. The ChatGPT/Codex
OAuth route is part of provider `openai` (API `openai-chatgpt-responses`, base
`https://chatgpt.com/backend-api/codex`) and needs an OAuth access token; runtime auth
refreshes it. OpenAI-compatible proxy providers keep using the SDK's HTTP transport so
proxy behavior stays explicit and configurable.

## Known Limitations

- Bedrock requests are not SigV4-signed; `aws-sdk` auth needs a signing proxy or
  gateway, and Bedrock streaming yields one final chunk.
- `request.proxy` and `request.tls` in provider configs are round-tripped but not
  applied, and `localService` is metadata only.

## Related Symbols

- ``ModelRouter``
- ``ProviderServiceConfig``
- ``OpenAIModelProvider``
- ``OpenClawConfig``
