# Getting Started

Install `OpenClawKit` with Swift Package Manager and start from ``OpenClawSDK``
unless you already know you need lower-level modules.

## Add the Package

```swift
dependencies: [
    .package(url: "https://github.com/MarcoDotIO/OpenClawKit.git", branch: "main")
]
```

Link the umbrella product in your target:

```swift
.product(name: "OpenClawKit", package: "OpenClawKit")
```

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

## Next Steps

- Configure providers and secrets in <doc:ConfigurationAndSecrets>
- Add durable session handling in <doc:ChannelsAndSessions>
- Validate your app with <doc:TestingAndValidation>
