# ChatUI and ChatStore

Build a native chat client on the upstream OpenClaw chat stack, with an offline store.

## Overview

`OpenClawChatUI` ports the upstream OpenClaw `2026.9.6` chat experience to SwiftUI:

- the non-view chat core (`OpenClawChatViewModel`, transports, wire models, gateway
  request builders, transcript-cache and outbox contracts) on every Apple platform;
- the views (`OpenClawChatView`, the split shell, composer, markdown and media
  rendering) on iOS, macOS and visionOS. tvOS and watchOS get the core only.

`OpenClawChatStore` adds a GRDB-backed transcript cache and durable command outbox.
GRDB is resolved for every consumer of the package but compiled only when you link
`OpenClawChatStore`. `OpenClawChatUI` depends on swift-markdown 0.8.0.

## Chat over a gateway

`OpenClawGatewaySessionChatTransport` is a ready-made transport over one
``GatewayNodeSession`` operator connection:

```swift
import OpenClawChatStore
import OpenClawChatUI
import OpenClawKit

var options = GatewayConnectOptions.defaultOperator(displayName: "My App")
options.deviceAuthGatewayID = gatewayID
try await session.connect(
    url: gatewayURL,
    token: token,
    connectOptions: options,
    sessionBox: nil,
    onConnected: {},
    onDisconnected: { _ in },
    onInvoke: { request in BridgeInvokeResponse(id: request.id, ok: false) })

let databases = try OpenClawClientDatabases(
    directoryURL: OpenClawClientDatabases.defaultDirectoryURL(appGroupIdentifier: nil))
let store = databases.store(gatewayID: gatewayID)

let viewModel = OpenClawChatViewModel(
    sessionKey: "main",
    transport: OpenClawGatewaySessionChatTransport(gateway: session, gatewayStableID: gatewayID),
    transcriptCache: store,
    outbox: store)

// In SwiftUI:
OpenClawChatView(viewModel: viewModel)
```

Pass the same gateway id as `gatewayStableID`, as `deviceAuthGatewayID` and to
`store(gatewayID:)`, so outbox replays stay bound to that gateway. Every queued or
durable operation (outbox flushes, settings, session mutations, groups, new sessions,
Swarm, model sign-in) captures a route lease first, so work suspended behind a
reconnect or a gateway switch is cancelled instead of being sent to another connection.

`OutboxRouteSafety.strict` (the default) replays queued commands only when the gateway
advertises `chat-send-routing-contract` (and settings CAS); older gateways get live
sends only. `.bestEffort` replays against the bound connection without those fences.

## Writing your own transport

`OpenClawChatTransport` v2 has about 60 requirements, each with a default that throws
"`<op>` not supported by this transport" or returns empty. Adopt
`OpenClawChatGatewayTransport` to get the gateway-backed session, question, task,
command and branch operations from four requirements (`chatGatewayAgentID`,
`sessionTarget(for:overrideAgentID:)`, `requestChatGateway(_:)`,
`requestChatSessionAction(_:)`).

- Implement `listModels(agentID:)` and `listSessions(limit:search:archived:)`; the
  legacy `listModels()` and `listSessions(limit:)` are deprecated.
- A conformer method whose labels, optionality or effects differ from a requirement is
  never called through `any OpenClawChatTransport`: the protocol default wins silently.
  `listSessions(limit:archived:)` is an extension convenience, not a requirement, so a
  conformer method with that signature is shadowed. The agent-scoped
  `listSessions(limit:search:archived:agentID:)` is a requirement whose default ignores
  the agent and calls `listSessions(limit:search:archived:)`.
- Protocol-v4 chat events are a union on state (`OpenClawChatEventState`): delta frames
  may carry a full message snapshot and/or `deltaText`, `replace` resets the buffer, and
  `status` and unknown states do not end a run.

## Rendering

- Markdown is block-structured (swift-markdown): headings, GFM tables, task lists,
  `<details>` disclosures, code cards with syntax highlighting and copy, and a
  word-paced streaming reveal that honors Reduce Motion and, on 27, reduced resource
  usage.
- Typography uses Inter, Red Hat Display and JetBrains Mono only when the host app
  registers them; otherwise the system text styles with Dynamic Type.
- Math: LaTeX renders as monospaced source (display math as a "LaTeX" code block).
  SwiftMath is not a dependency.
- Mermaid: fences render only through a host-supplied renderer
  (`.openClawChatMermaidRenderer(_:)`); no JavaScript is bundled. A renderer built from
  upstream `packages/mermaid-renderer` must carry the Mermaid (MIT) and DOMPurify
  (Apache-2.0/MPL-2.0) notices.
- Tool activity rows with inline diffs, completed-work folding, working status, progress,
  question and credential cards, subagent and Swarm progress, inline media with one
  active player, sandboxed inline canvas widgets (WKWebView), cited sources, transcript
  export (`ChatTranscriptExporter`) and find in conversation.
- Link previews are off by default. Enable them with
  `OpenClawChatDisplayOptions.linkPreviews`; a chip fetches only after a tap, through an
  SSRF-guarded fetcher (public addresses only, http(s), 512 KB HTML, 1 MB images, 3
  redirects, 6 s), and each fetch reveals the viewer's IP address to the linked site.
- The working indicator is pluggable
  (`.openClawChatWorkingIndicatorStyle(.custom(OpenClawChatWorkingIndicator { context in … }))`).

## Shell, composer and preferences

`OpenClawChatView` follows upstream: composer v2 with slash commands, a provider-grouped
model picker with pinned and recent models, thinking/verbose/fast/effort controls (the
thinking picker offers Max and Ultra only where the catalog allows, is hidden for
`apple-fm/system` and shown for `apple-fm/private-cloud-compute`), context usage, input
history, reply preview and attachments. The "Execution permissions" menu patches only
`permissionMode` (read-only, guarded, workspace, full) and never sends
`execSecurity`/`execAsk`.

`OpenClawChatSplitView` and `OpenClawChatWindowShell` compose sessions and chat for macOS,
iPadOS, visionOS and iPhone, with session groups, pin/archive/unread/color, rename,
fork, rewind and branches. Talk, dictation and voice-note controls are host-provided.
`OpenClawChatUIPreferences` applies `ui.prefs` (`chatShowThinking`, `chatShowToolCalls`,
`chatSendShortcut`, `themeMode`) and the gateway user accent.

Strings are English literals resolved from the host app's main bundle, like upstream;
localize by adding the keys to your own string catalog.

On OS 27 the composer accepts iOS paste destinations and an Image Playground sheet, and
assistant text can show data detection, LinkSecurity flags and suggested actions (see
<doc:AppIntentsAndSystemIntegration>).

## Offline store

`OpenClawClientDatabases` owns two SQLite files in its directory (Application Support,
or `<app group>/OpenClawKit/ChatStore` when you pass an App Group):

- `gateway-cache.sqlite` is disposable and rebuilt when its format changes;
- `client-state.sqlite` holds the outbox, routing identity and Watch journal, uses
  forward-only migrations and is never reset.

The directory is created `0700` and files `0600` with
`completeUntilFirstUserAuthentication` protection, so background outbox flushes and
Watch replies can read it. Forgetting a gateway (`removeGatewayData(gatewayID:)`)
leaves a hash-only tombstone. `OpenClawWatchMessageJournal` is only relevant to apps
whose Watch app uses OpenClaw's WatchConnectivity chat-delivery protocol.
