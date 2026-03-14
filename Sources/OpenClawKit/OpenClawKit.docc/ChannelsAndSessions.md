# Channels and Sessions

`OpenClawKit` separates inbound message delivery from session persistence so the
same runtime can serve web chat, bots, and app-hosted conversations.

## Session Persistence

Use ``SessionStore`` when you need durable routing state across launches or
server restarts. The SDK facade exposes helper methods to load and save a
file-backed store.

## High-Level Reply Routing

For app-hosted chat or bot flows, start with
``OpenClawSDK/getReplyFromConfig(config:sessionStoreURL:inbound:diagnosticsPipeline:)``.
That path resolves the effective session key, invokes the runtime, and returns
an ``OutboundMessage`` you can hand back to the transport that delivered the
user message.

## Optional Shared Chat UI

`OpenClawChatUI` packages a reusable view model and transport contract for
SwiftUI clients that want a hosted chat surface without reimplementing session
polling, model selection, or transport event handling.

## Related Symbols

- ``SessionStore``
- ``SessionRoutingContext``
- ``InboundMessage``
- ``OutboundMessage``
- ``OpenClawChatViewModel``
- ``OpenClawChatTransport``
