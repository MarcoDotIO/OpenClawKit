# Provider Routing and Fast Mode

Model execution flows through `OpenClawModels`, with `OpenClawKit` re-exporting
the routing and provider types for app-level use.

## Router Behavior

``ModelRouter`` chooses providers from the configured catalog, applies auth
resolution, and can fall back across compatible providers when one endpoint is
unavailable.

## Fast Mode

Fast mode can be defined per-model in config and overridden per session. The
current parity behavior maps fast mode onto provider-specific low-latency
settings where those APIs support them.

## OpenAI and Codex

Direct OpenAI and Codex-backed OpenAI traffic uses the OpenAIKit-backed client
path. OpenAI-compatible proxy providers continue to use the SDK's custom HTTP
transport so proxy behavior stays explicit and configurable.

## Related Symbols

- ``ModelRouter``
- ``ProviderServiceConfig``
- ``OpenAIModelProvider``
- ``OpenClawConfig``
