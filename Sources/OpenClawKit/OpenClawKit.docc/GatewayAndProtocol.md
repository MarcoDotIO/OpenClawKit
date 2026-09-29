# Gateway and Protocol v4

Connect to OpenClaw gateways and host an in-process gateway with your own methods.

## Overview

OpenClawKit speaks the OpenClaw gateway protocol v4 (`GATEWAY_PROTOCOL_VERSION`),
vendored from upstream `v2026.9.6`. The same models back three roles:

- an operator client (``GatewayChannelActor``) for apps that drive a remote gateway,
- a node session (``GatewayNodeSession``) for devices that serve node commands,
- an in-process `GatewayServer` (OpenClawGateway) that embeds the runtime in your app.

`GatewayMethodCatalog` lists the 482 upstream core methods with their scope, `since`
version, advertised and startup-gated flags, and validates params for 324 of them.

## Connecting as an operator

```swift
import OpenClawKit

var options = GatewayConnectOptions.defaultOperator(displayName: "My App")
options.deviceAuthGatewayID = gatewayStableID     // scopes stored device tokens to this gateway

let channel = GatewayChannelActor(
    url: URL(string: "wss://gateway.example.com")!,
    token: sharedToken,
    pushHandler: { push, generation in await model.handle(push, generation: generation) },
    connectOptions: options,
    disconnectHandler: { reason, generation in await model.disconnected(reason) })

try await channel.connect()
let data = try await channel.request(method: "sessions.list", params: ["limit": AnyCodable(20)])
```

- Operator connects negotiate protocol 4. Set `options.minimumProtocolVersion = 3` for
  pre-v4 gateways and gate v4-only UI on `negotiatedProtocolVersion()`.
- hello-ok is decoded defensively. Read the negotiated policy with
  `currentHelloPolicy()` (tick interval, payload and attachment ceilings); requests over
  the advertised payload limit fail locally with `GatewayRequestError.payloadTooLarge`.
- The device proof is signed with the server's `connect.challenge` time, so clock skew
  no longer causes `DEVICE_AUTH_SIGNATURE_EXPIRED`.
- Call `reconnectIfStale()` when the app becomes active and `nudgeReconnect()` when the
  network path changes. Connect callers share one attempt and failures back off from
  500 ms to 30 s.
- Turn errors into user-facing guidance with `GatewayConnectionProblemMapper.map(error:preserving:)`.
  Its strings are English defaults plus localization keys.
- Send the profile id from `users.self` with
  `request(method:params:timeoutMs:expectedProfileID:)` when a request must not run under
  another profile.

## Transport security and TLS

`GatewayTransportSecurityPolicy.evaluate(url:)` classifies a gateway URL as `ok`,
`warnCleartextLAN` (confirm with the user), `requireTLS` or `rejectNonRoutable`.
Tailscale and single-label hosts are not local, so they need `wss://`.

`GatewayTLSPinningSession` enforces stored pins, pins on first use only for
system-trusted certificates, and binds challenges to the requested host and port. When
a pin changes, the channel pauses automatic reconnects:

```swift
if let rotation = await channel.pendingTLSPinRotationRequest() {
    // Show old and new fingerprints; accept only after the user confirms.
    _ = await channel.acceptTLSPinRotation(rotation)
}
```

Managed (MDM) hosts can pass a `ManagedGatewayClientIdentity` for mutual TLS and extra
trust anchors. Stage planned certificate renewals with `GatewayTLSStore.stageNextFingerprint`.

## Node sessions

``GatewayNodeSession`` serves node commands (`system.run`, `screen.snapshot`,
`computer.act`, `health.summary`, `camera.*`, …) for a gateway. Build connect options
with `GatewayConnectOptions.defaultNode(caps:commands:permissions:)`, add
`reportingPermissions(await OpenClawPermissionsSnapshot.current())` and
`applyingGatewayConfig(_:)`, and answer invokes in `onInvoke`. Route leases
(`currentRoute()`, `request(…ifCurrentRoute:)`) keep cleanup and queued work bound to
the connection that started it. Never show a permission prompt for a remote invoke:
return `OpenClawNodeError.permissionRequired(_:)` instead.

## Hosting an in-process gateway

`OpenClawSDK.makeEmbeddedAgentStack(stateDirectory:credentialStore:)` returns a
`GatewayServer` with the agent runtime attached. You can also build one with
``OpenClawSDK/makeGatewayServer(sessionStore:credentialStore:modelRouter:runtime:workspaceRoot:secretIndexURL:browserRequestHandler:)``
and register handlers yourself.

Dispatch is table-driven:

- Registered handlers run after role and scope checks (`FORBIDDEN` with
  `MISSING_SCOPE` details on failure).
- Known upstream methods without a handler validate their params and answer
  `UNAVAILABLE`; removed and unknown methods answer `INVALID_REQUEST`.
- Upstream wire shapes (`runId`, `agentId`, `AgentParams`, null clears) and the legacy
  SDK keys both decode.

## Registering methods

Feature modules expose `register…GatewayMethods(on registrar: some GatewayMethodRegistrar)`
functions. Call the ones you need after creating the server:

```swift
await registerChannelGatewayMethods(on: server, context: channelContext)
await registerSkillsGatewayMethods(on: server, configuration: skillsConfiguration)
await registerMemoryGatewayMethods(on: server, configuration: memoryConfiguration)
await registerCronGatewayMethods(on: server, scheduler: scheduler)
await runtime.attach(to: server)
```

Register your own methods the same way. Handlers get a `GatewayMethodRequest` with
params, the connection context (role, scopes, client) and an event emitter, and throw
`GatewayMethodError` for wire error codes:

```swift
struct EchoParams: Decodable, Sendable { let text: String }
struct EchoResult: Encodable, Sendable { let text: String }

await server.register(method: "example.echo", params: EchoParams.self) { params, request in
    await request.events.emit("example.echoed", payload: AnyCodable(["text": AnyCodable(params.text)]))
    return EchoResult(text: params.text)
}
```

Methods in `GatewayServer.sdkExtensionMethods` (`agent.run`, `skills.list`,
`skills.invoke`, `secrets.list/set/delete`, `browser.request`) are OpenClawKit
extensions, not upstream core methods.

## Events and startup gating

`GatewayServer.events(filter:bufferingNewest:)` streams `agent`, v4 `chat`,
`session.message`, `session.tool`, `sessions.changed`, approval, question,
progress-card, task and cron events with a server-global `seq`. A slow subscriber loses
its oldest frames, which shows up as a gap in `seq`. `LoopbackGatewaySocket` clients
receive session-scoped events only after `sessions.messages.subscribe`.

Gate methods until hosted subsystems are ready:

```swift
try await server.runStartup {
    try await warmUpStores()
}
```

Until `runStartup` (or `completeStartup()`) finishes, startup-gated methods answer the
retryable `startup-sidecars` `UNAVAILABLE` error, which `GatewayClient` and
``GatewayChannelActor`` retry automatically.

## Reading AnyCodable

`AnyCodable` is an enum-backed `Sendable` type. Read it with the typed accessors, never
`value as? T`:

```swift
let payload = frame.payload?.dictionaryValue ?? [:]
let text = payload["text"]?.stringValue
let count = payload["count"]?.intValue
let sentAtMs = payload["sentAtMs"]?.int64Value   // Int64: watchOS Int is 32-bit
```

On arm64_32 watchOS, integers above `Int32.max` decode as `.double`, so read
millisecond timestamps with `int64Value`. The generated protocol models keep upstream's
`Int` fields.

## Related Symbols

- ``GatewayChannelActor``
- ``GatewayNodeSession``
- ``GatewayConnectOptions``
- ``OpenClawSDK``
