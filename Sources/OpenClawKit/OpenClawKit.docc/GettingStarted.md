# Getting Started

Install `OpenClawKit` with Swift Package Manager and start from ``OpenClawSDK``
unless you already know you need lower-level modules.

## Add the Package

```swift
dependencies: [
    .package(url: "https://github.com/MarcoDotIO/OpenClawKit.git", from: "2026.3.1")
]
```

Link the umbrella product in your target, plus any Apple-only products you use:

```swift
.product(name: "OpenClawKit", package: "OpenClawKit"),
.product(name: "OpenClawChatUI", package: "OpenClawKit"),      // SwiftUI chat
.product(name: "OpenClawChatStore", package: "OpenClawKit"),   // offline chat store (GRDB)
.product(name: "OpenClawAppIntents", package: "OpenClawKit"),  // Siri and Shortcuts
.product(name: "OpenClawNativeState", package: "OpenClawKit"), // low-level state database
```

Build with Xcode 27.1 (Swift 6.4). The package floors are iOS 17, macOS 14, tvOS 17,
watchOS 10 and visionOS 26; Apple 27 features are availability-gated. Linux services
depend on the cross-platform products (`OpenClawCore`, `OpenClawAgents`,
`OpenClawGateway`, …), which build with Swift 6.2.

## Create a Reply Flow

```swift
import OpenClawKit

let sdk = OpenClawSDK.shared
let diagnostics = sdk.makeDiagnosticsPipeline(eventLimit: 500)

let outbound = try await sdk.getReplyFromConfig(
    config: OpenClawConfig(),
    sessionStoreURL: URL(fileURLWithPath: "./state/sessions.json"),
    inbound: InboundMessage(
        channel: .webchat,
        peerID: "user-1",
        text: "Summarize today's support queue."
    ),
    diagnosticsPipeline: diagnostics
)

print(outbound.text)
```

## Run a Persistent Embedded Agent

``OpenClawSDK/makeEmbeddedAgentStack(stateDirectory:credentialStore:modelRouter:agentID:workspaceRoot:loopConfiguration:toolsConfiguration:)``
creates session and transcript stores, an agent runtime with the tool-calling loop,
`ask_user`, sub-agents, goals, a task ledger and progress cards, and an in-process
gateway with every runtime method registered:

```swift
let router = ModelRouter()
await router.register(FoundationModelsProvider())

let stack = try await sdk.makeEmbeddedAgentStack(
    stateDirectory: stateDirectory,
    credentialStore: KeychainCredentialStore(service: "com.example.myapp"),
    modelRouter: router)

let result = try await stack.runtime.run(AgentRunRequest(sessionKey: "main", prompt: "Plan my week."))
print(result.output)
```

Use `stack.runtime.runEvents(_:)` to stream lifecycle, assistant, thinking, tool and
usage events to your UI.

## Connect to a Gateway

To drive a remote OpenClaw gateway, connect a ``GatewayChannelActor`` (operator) or a
``GatewayNodeSession`` and put `OpenClawChatView` on top of
`OpenClawGatewaySessionChatTransport`. See <doc:GatewayAndProtocol> and
<doc:ChatUIAndChatStore>.

## Next Steps

- Upgrading from 2026.2.x: <doc:MigratingTo2026_3>
- Configure providers and secrets in <doc:ConfigurationAndSecrets>
- Add durable session handling and channels in <doc:ChannelsAndSessions>
- Run on Apple Intelligence with <doc:AppleIntelligence>
- Validate your app with <doc:TestingAndValidation>
