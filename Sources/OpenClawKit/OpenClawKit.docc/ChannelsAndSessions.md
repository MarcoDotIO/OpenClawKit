# Channels and Sessions

`OpenClawKit` separates inbound message delivery from session persistence so the
same runtime can serve web chat, bots, and app-hosted conversations.

## Session Persistence

Use ``SessionStore`` when you need durable routing state across launches or
server restarts. The SDK facade exposes helper methods to load and save a
file-backed store. Session records carry the `2026.9.6` session controls
(`permissionMode`, `traceLevel`, fast mode, tool overrides, archive, pin and unread
state) and `Int64` millisecond timestamps. With a transcript store, the embedded
runtime keeps each session's messages as a tree of entries with compaction and reset
boundaries.

## High-Level Reply Routing

For app-hosted chat or bot flows, start with
``OpenClawSDK/getReplyFromConfig(config:sessionStoreURL:inbound:diagnosticsPipeline:)``.
That path resolves the effective session key, invokes the runtime, and returns
an ``OutboundMessage`` you can hand back to the transport that delivered the
user message.

## Access Policy and Pairing

Channels enforce the upstream ingress access policy. DMs default to
`dmPolicy: pairing`: an unknown sender receives an 8-character code (one-hour TTL, at
most three pending requests per account) and the model does not run until the
sender is approved. Groups default to `groupPolicy: allowlist` with a required
mention. The SDK WebChat channel is exempt.

```swift
let pairing = ChannelPairingStore(stateDirectory: stateDirectory)
let engine = AutoReplyEngine(
    config: config,
    sessionStore: sessions,
    channelRegistry: registry,
    runtime: runtime,
    pairingStore: pairing)

await adapter.setInboundHandler { inbound in
    _ = try? await engine.handle(inbound)   // reports pairing and policy outcomes
}
```

Approve senders with the store (`list()`, `approve(channel:accountID:requestID:)`) or
through the `channels.pairing.*` gateway methods served by
`registerChannelGatewayMethods(on:context:)`. To opt out, set `dmPolicy`, `allowFrom`
and `groupPolicy` per channel, or `channels.compatibility.ingressAccessPolicy` to
`"legacy-allow-all"`.

`InboundMessage.accountID` is the channel account key (`nil` for the default account)
and the platform user is in `senderID`. Built-in adapters use `<channel>:<peer>`
session keys; set `channels.compatibility.legacySessionAccountKeys` to keep the
2026.2 keys.

## Delivery

Replies are chunked per channel (fence-aware, with each channel's unit and limit) and
only the first chunk carries the native reply target. Sends report receipts, and
failures are classified (`ChannelSendError`) so that sends with an unknown outcome are
not retried blindly and `Retry-After` is honored (capped at 60 seconds). Bot-loop
protection, acknowledgement reactions and a capability-driven typing indicator are
built into `AutoReplyEngine`.

Native adapters cover Telegram, Discord, Slack, Signal, Google Chat, Microsoft Teams,
WhatsApp Cloud, iMessage (through `imsg` on macOS), SMS over Twilio, A2A, LINE, WebChat
and, on iOS 26 or later, carrier messaging. Adapters that serve webhooks (SMS, A2A,
LINE, Slack events) expose handlers that the host routes HTTP requests to.

## Optional Shared Chat UI

`OpenClawChatUI` packages a reusable view model and transport contract for
SwiftUI clients that want a hosted chat surface without reimplementing session
polling, model selection, or transport event handling. See <doc:ChatUIAndChatStore>.

## Related Symbols

- ``SessionStore``
- ``SessionRoutingContext``
- ``InboundMessage``
- ``OutboundMessage``
- ``AutoReplyEngine``
- ``ChannelPairingStore``
- `OpenClawChatViewModel` (OpenClawChatUI)
- `OpenClawChatTransport` (OpenClawChatUI)
