# Migrating to 2026.3

Update an app or service from OpenClawKit 2026.2.x to 2026.3.0.

## Overview

OpenClawKit 2026.3.0 tracks upstream OpenClaw `v2026.9.6` and adopts the Apple 27
SDKs. Most changes are additive, but a few change runtime behavior on upgrade. Work
through the sections below in order; each one shows the old code, the new code and
what to check. The full list is in the "Breaking changes" section of `CHANGELOG.md`.

Before you start:

- Build with Xcode 27.1 (Swift 6.4). The package floors are unchanged (iOS 17,
  macOS 14, tvOS 17, watchOS 10, visionOS 26) and the cross-platform modules still
  build with Swift 6.2 on Linux.
- Update the dependency to `from: "2026.3.0"`.
- Expect new enum cases. Exhaustive `switch` statements over SDK enums need the new
  cases or a `default:` branch.

## Gateway protocol v4

Operator connections now require protocol 4, the upstream default. Gateways older
than `2026.8` (protocol 3) reject them.

```swift
// 2026.2.x: connected to any gateway.
let channel = GatewayChannelActor(url: url, token: token, pushHandler: handlePush)

// 2026.3.0: opt in to protocol 3 for legacy gateways, and gate v4-only UI.
var options = GatewayConnectOptions.defaultOperator(displayName: "My App")
options.minimumProtocolVersion = 3
let channel = GatewayChannelActor(url: url, token: token, connectOptions: options)
try await channel.connect()
if await channel.negotiatedProtocolVersion() ?? 0 >= 4 {
    // Use v4-only features (for example Talk sessions).
}
```

Node-role connections already offer protocol 3...4.

## Gateway callbacks receive the socket generation

``GatewayChannelActor``'s primary initializer passes the socket generation to its
callbacks, so late events from a retired socket can be ignored. The single-argument
initializer still compiles but is deprecated and requires `pushHandler`.

```swift
// 2026.2.x
let channel = GatewayChannelActor(
    url: url,
    token: token,
    pushHandler: { push in await model.handle(push) },
    disconnectHandler: { reason in await model.disconnected(reason) })

// 2026.3.0
let channel = GatewayChannelActor(
    url: url,
    token: token,
    pushHandler: { push, generation in await model.handle(push, generation: generation) },
    connectOptions: .defaultOperator(displayName: "My App"),
    disconnectHandler: { reason, generation in await model.disconnected(reason, generation: generation) })
```

Also note:

- The default operator client id is per platform (`openclaw-macos`, `openclaw-ios`,
  `openclaw-watchos`) and the default scopes add `operator.questions`.
- The device proof is signed with the server's `connect.challenge` time. A challenge
  without an integral `ts` fails the connect, as upstream does. v3 proofs are opt-in
  with `deviceProofPayload = .v3`.
- The connect handshake budget is 30 s (`handshakeTimeoutMs` overrides it), and
  `connect()` after `shutdown()` throws.
- Call `reconnectIfStale()` when the app becomes active and `nudgeReconnect()` on
  network changes.

## Generated protocol types

`OpenClawProtocol` is regenerated from upstream `v2026.9.6`.

```swift
// 2026.2.x
if let error = response.error, let code = error["code"]?.value as? String { … }
let canvasURL = hello.canvashosturl

// 2026.3.0
if let error = response.error {                  // ErrorShape?
    let code = error.errorCode                   // typed ErrorCode?
    let details = error.typedDetails             // GatewayErrorDetails?
    print(code as Any, error.message, details as Any)
}
let canvasURL = hello.pluginsurfaceurls?["canvas"]
```

- Removed types: `SessionsCompaction{List,Get,Branch,Restore}{Params,Result}`,
  `SessionCompactionCheckpoint`, `TalkRealtimeSession{Params,Result}`,
  `NodePairRequestParams`, `NodePairVerifyParams`, and the spawn-lineage fields of
  `SessionsPatchParams`. Use the Talk session methods (`TalkGatewayClient`) instead
  of `talk.realtime.session`.
- `HelloOk.auth` is non-optional, `Snapshot.updateavailable` is the typed
  `UpdateAvailable`, and `SessionsSendParams.attachments` is `[[String: AnyCodable]]?`.
- `GatewayAgentAccepted`, `GatewayAgentWaitParams` and `GatewayAgentWaitResult` encode
  `runId` (they still decode `runID`). Third-party decoders must read `runId`.
- `GatewayResponseError.details` is flattened like upstream: nested details plus
  `code`, `message`, `retryable` and `retryAfterMs`.

Read `AnyCodable` with the typed accessors. `value as? T` does not work with the
enum-backed type:

```swift
let count = payload["count"]?.intValue
let sentAt = payload["sentAtMs"]?.int64Value     // use Int64 for millisecond timestamps
let enabled = payload["enabled"]?.boolValue      // JSON 0/1 are numbers, not booleans
```

## In-process gateway changes

`GatewayServer` dispatch is table-driven:

- Methods removed upstream (`sessions.compaction.*`, `talk.realtime.session`,
  `node.pair.request`, `node.pair.verify`, `sessions.unsubscribe`,
  `node.canvas.capability.refresh`) and unknown methods answer `INVALID_REQUEST`
  (`unknown method: X`). Known upstream methods without a handler answer `UNAVAILABLE`.
- Requests are authorized by role and scope. `handle(_:)` still uses an
  `operator.admin` in-process context, so existing callers keep working.
- `sessions.patch` rejects `execSecurity` and `execAsk`, even as `null`. Send
  `permissionMode` instead.
- `LoopbackGatewaySocket` delivers `session.message` and `session.tool` only after the
  connection subscribes with `sessions.messages.subscribe`. Give each socket its own
  `connectionID`.

Register your own methods with the public registration API (see <doc:GatewayAndProtocol>)
instead of patching the server.

## Millisecond timestamps are Int64

`Int` is 32-bit on arm64_32 Apple Watch, so SDK-owned millisecond timestamps are now
`Int64`: `DeviceIdentity.createdAtMs`, `DeviceAuthEntry.updatedAtMs`,
`SessionRecord.updatedAtMs`, `ResolvedSessionState.updatedAtMs`,
`GatewaySessionInfo.updatedAtMs`, `ConversationMemoryEntry.createdAtMs`,
`PairingRecord.approvedAtMs`, the auth-profile timestamps and
`OpenClawWatchNotifyParams.expiresAtMs` (`Int64?`). The signed-at parameters of
`GatewayDeviceAuthPayload` take `Int64` too.

```swift
// 2026.2.x
let updated: Int = record.updatedAtMs

// 2026.3.0: literals still compile; convert Int variables.
let updated: Int64 = record.updatedAtMs
let entry = DeviceAuthEntry(token: token, role: "operator", scopes: scopes, updatedAtMs: Int64(nowMs))
```

## Device identity moves to native state

``DeviceIdentityStore`` and ``DeviceAuthStore`` persist to
`<stateDir>/state/openclaw.sqlite` (`OpenClawNativeState`). On first use the SDK
imports `identity/device.json` and `identity/device-auth.json` once, keeps the
`deviceId` and tokens, and deletes the JSON files. Users do not re-pair.

```swift
// 2026.2.x
let identity = DeviceIdentityStore.loadOrCreate()

// 2026.3.0: throwing, and never silently rotates a stored identity.
let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)
// From an actor, keep SQLite work off the cooperative pool:
let identity = try await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: .primary)
```

- The deprecated `loadOrCreate()` no longer crashes on storage failure; it logs and
  returns an ephemeral identity that a gateway sees as a new, unpaired device.
- Downgrading to 2026.2.x after the import finds no `device.json`, creates a new
  identity and requires re-pairing.
- ``GatewayChannelActor`` connect throws when the identity cannot be persisted.
- Extensions share identity only through the App Group named by the Info.plist key
  `OpenClawAppGroupIdentifier`. See <doc:NativeStateAndDeviceIdentity>.

## Channels default to DM pairing

Channels enforce the upstream ingress access policy. DMs default to
`dmPolicy: pairing`, so an unknown sender gets an 8-character pairing code and the
model does not run until you approve it. Groups default to `groupPolicy: allowlist`
with `requireMention`. The SDK WebChat channel is exempt.

```swift
// 2026.2.x: every sender reached the agent.
let engine = AutoReplyEngine(config: config, sessionStore: sessions,
                             channelRegistry: registry, runtime: runtime)
adapter.setInboundHandler { inbound in _ = try? await engine.process(inbound) }

// 2026.3.0: persist pairing state and approve senders.
let pairing = ChannelPairingStore(stateDirectory: stateDirectory)
let engine = AutoReplyEngine(config: config, sessionStore: sessions,
                             channelRegistry: registry, runtime: runtime,
                             pairingStore: pairing)
adapter.setInboundHandler { inbound in
    _ = try? await engine.handle(inbound)        // reports pairing and policy outcomes
}
for listing in try await pairing.list() {
    _ = try await pairing.approve(channel: listing.channel, requestID: listing.requestID)
}
```

To keep the old behavior, configure `allowFrom`/`dmPolicy` per channel or set
`channels.compatibility.ingressAccessPolicy` to `"legacy-allow-all"`.
`AutoReplyEngine.process(_:)` now throws `AutoReplyIngressRejection` when nothing is
sent; use `handle(_:)` or `processIfAllowed(_:)` to observe that without an error.

## Channel account keys and session keys

`InboundMessage.accountID` now means the channel account key (upstream `accountId`;
`nil` is the default account). Built-in adapters put the platform user in the new
`senderID`, and their session keys change from `<channel>:<sender>:<peer>` to
`<channel>:<peer>`.

```json
{
  "channels": {
    "compatibility": { "legacySessionAccountKeys": true }
  }
}
```

Set `legacySessionAccountKeys` to keep existing session keys and conversation memory.
Custom adapters that send typing indicators must also return `true` from
`supportsTypingIndicator`, and channel secret `String` properties return `nil` for
SecretRef or `${ENV}` values until you call `ChannelsConfig.resolvingSecrets(using:)`.

## Provider identity: apple-fm, google, openai

```swift
// 2026.2.x
await router.register(FoundationModelsProvider()) // id "foundation"
let request = ModelGenerationRequest(sessionKey: "s", prompt: p,
                                     providerID: "foundation", modelID: "apple-foundation-default")

// 2026.3.0
await router.register(FoundationModelsProvider()) // id "apple-fm"
let request = ModelGenerationRequest(sessionKey: "s", prompt: p,
                                     providerID: FoundationModelsProvider.providerID,
                                     modelID: FoundationModelsProvider.systemModelID)
```

- `ModelRouter` does not resolve aliases. Use the constants, register
  `FoundationModelsProvider(id: "foundation")` for stored routes, or migrate refs with
  `OpenClawReferenceProviderCatalog.canonicalizeModelRef(_:)`.
- Responses report model `system` (or `private-cloud-compute`); `apple-foundation-default`
  is accepted as an input alias.
- `gemini`, `foundation`, `kimi-coding`, `modelstudio` and `openai-codex` are catalog
  aliases of `google`, `apple-fm`, `kimi`, `qwen` and `openai`. `openai-codex/<model>`
  resolves to `openai/<model>` on the ChatGPT OAuth route (API
  `openai-chatgpt-responses`, runtime hint `codex`).
- `ProviderCapability.memoryEmbedding` is `.embedding` (raw value `embedding`).
- The ChatGPT login loopback callback is `http://localhost:1455/auth/callback`
  (was `http://127.0.0.1:1455/oauth-callback`). Update registered redirect URIs.

## Provider configuration

```json
// 2026.2.x
{ "models": { "providers": { "anthropic": { "baseURL": "https://api.anthropic.com/v1" } } } }

// 2026.3.0: upstream key; Anthropic appends /v1/messages unless the base ends in /v1.
{ "models": { "providers": { "anthropic": { "baseUrl": "https://api.anthropic.com" } } } }
```

- Configs decode `baseURL` and encode `baseUrl`; encoding omits SDK-only and default
  values. A missing `baseUrl` is filled from the catalog.
- `apiKey` and provider `headers` accept SecretInput (plaintext, `${ENV}` or SecretRef).
- Ollama calls native `/api/chat`; the default request timeout is 120 s.
- `ModelProviderFactory.makeProvider` throws for an unrecognized `api` and may return
  `RoutingModelProvider`. Do not depend on concrete factory return types.
- OpenAI Responses fast mode no longer lowers reasoning effort or verbosity.

## Custom model providers and the agent loop

The runtime no longer derives `ModelGenerationPolicy.reasoningEffort` from `ThinkLevel`.

```swift
// 2026.2.x
let effort = request.policy.reasoningEffort

// 2026.3.0: resolve the provider's effort from the requested thinking level.
let effort = ReasoningEffortResolver.resolve(
    thinkingLevel: request.policy.thinkingLevel ?? .off,
    model: nil,
    modelID: request.modelID ?? "my-model",
    providerID: self.id,
    api: nil)
```

Declare `capabilities` (`ModelProviderCapabilities`) to receive transcript `messages`
and `tools`. Providers that declare `supportsTools` or `supportsTranscript` run the
multi-turn tool loop; legacy providers keep the single composed prompt. Tool Search
moves non-direct tools behind `tool_search` once 12 or more tools are visible:

```swift
let runtime = EmbeddedAgentRuntime(
    toolsConfiguration: AgentToolsConfiguration(toolSearch: ToolSearchConfiguration(enabled: false)),
    loopConfiguration: AgentLoopConfiguration())
```

`EmbeddedAgentRuntime` no longer connects to `ws://127.0.0.1:18789` or sends
`agent.run`; `gatewayClient` is optional.

## Configuration and secrets

- `OpenClawConfig` decoding is lenient: an unknown enum value becomes `nil` or the
  default and is recorded as a `ConfigDecodeIssue` instead of failing. Inspect issues
  with `ConfigDecodeIssueCollector.decode(OpenClawConfig.self, from: data)` if you
  relied on decode failures.
- A SecretInput string shaped like `$NAME` is an env SecretRef. Store literal secrets
  of that shape through a `file` or `store` SecretRef.
- Placeholder shared secrets (`changeme`, redaction sentinels, template stubs) fail
  `GatewayAuthConfig.validationErrors()`.
- File SecretRefs must be regular, single-link files owned by the current user with no
  group or world access (`chmod 600`). Exec SecretRef commands must be absolute,
  non-symlink, owned by the current user and inside `trustedDirs` when set.
- `ConfigStore.save` merges onto the file on disk and sorts keys.
- `OpenClawConfigDocument.Channels` is `ChannelsConfigDocument`; non-builtin channel
  blocks live in `ChannelsConfig.extensionChannels`.

## Network security and TLS

- Cleartext `ws://` to Tailscale (`*.ts.net`, `*.tailscale.net`, `100.64.0.0/10`) or
  single-label hosts is rejected. Use `wss://` (for example Tailscale Serve), or opt
  back in process-wide with `LocalNetworkHostPolicy.current = .legacyPermissive`.
- First-use TLS pinning requires a system-trusted certificate, stored pins are
  enforced, and a pin mismatch stops automatic reconnects:

```swift
if let rotation = await channel.pendingTLSPinRotationRequest() {
    // Show both fingerprints; call this only after the user confirms.
    _ = await channel.acceptTLSPinRotation(rotation)
}
```

- `ShareGatewayRelaySettings` stores its token and password in the Keychain and follows
  `OpenClawAppGroupIdentifier` (Info.plist, in the app and every extension) instead of
  `group.ai.openclaw.shared`. Add the keychain access-group entitlement; an
  extension-first upgrade needs a reconnect from the host app.

## Chat transports

`OpenClawChatTransportEvent` has new cases, and `OpenClawChatTransport` gained about 60
requirements, each with a default. `listModels()` and `listSessions(limit:)` are
deprecated:

```swift
// 2026.3.0: implement the v2 requirements…
func listModels(agentID: String?) async throws -> [OpenClawChatModelChoice] { … }
func listSessions(limit: Int?, search: String?, archived: Bool) async throws -> OpenClawChatSessionsListResponse { … }

// …or use the ready-made gateway transport.
let transport = OpenClawGatewaySessionChatTransport(gateway: session, gatewayStableID: gatewayID)
```

Methods whose labels, optionality or effects differ from a requirement are never called
through `any OpenClawChatTransport`; the protocol default wins silently. See
<doc:ChatUIAndChatStore>.

## Audio and Talk

`StreamingPlaybackResult` gains `finished` and `interruptedAt`, and the
`#if canImport(ElevenLabsKit)` typealiases are gone.

```swift
// A custom PCMStreamingAudioPlaying player that was stopped early:
return StreamingPlaybackResult(finished: false, interruptedAt: elapsed, durationSeconds: total)
```

Return `finished: false` when stopped so `TalkSpeechFallbackChain` does not also play
the system voice. Wrap ElevenLabsKit players in a small adapter.

## Deprecated APIs to replace

| Deprecated | Replacement |
| --- | --- |
| `DeviceIdentityStore.loadOrCreate()` | `loadOrCreatePersistedOrThrow(profile:)` |
| `ModelAPI.openAICodexResponses` | `.openAIChatGPTResponses` |
| `ProviderCapability.memoryEmbedding` | `.embedding` |
| `ModelCompatConfig.requiresMistralToolIDs` | (retired upstream) |
| `OpenClawChatTransport.listModels()` / `listSessions(limit:)` | `listModels(agentID:)` / `listSessions(limit:search:archived:)` |
| `GatewayNodeSession.refreshNodeCanvasCapability` | `refreshPluginSurfaceUrl(surface:timeoutSeconds:)` |
| `BridgeHelloOk.canvasHostUrl` | `GatewayNodeSession.pluginSurfaceURL("canvas")` |
| `GatewayConnectChallengeSupport.nonce(from:)` | `challenge(from:)` |
| `BlueBubblesChannelAdapter` | iMessage (`ChannelsConfig.migrateBlueBubblesToIMessage()`) |
| Canvas A2UI, `canvas.eval`, `canvas.snapshot` | the canvas presenter commands |
| `HookName.beforeAgentStart` | `.beforeAgentRun` |

## Checklist

1. Build with Xcode 27.1 and fix new enum cases and `Int64` conversions.
2. Decide on protocol 4 or `minimumProtocolVersion = 3` for older gateways.
3. Replace `loadOrCreate()`, and remember that downgrading after the identity import requires re-pairing.
4. Wire `ChannelPairingStore` approvals or configure `dmPolicy`/`allowFrom`.
5. Set `legacySessionAccountKeys` if you need the 2026.2 session keys.
6. Replace `foundation` literals with `FoundationModelsProvider` constants.
7. Re-save provider configs (`baseUrl`) and review secret files and exec providers.
8. Add `OpenClawAppGroupIdentifier` to the app and extensions that share state.
9. Update custom providers to read `thinkingLevel` and declare capabilities.
