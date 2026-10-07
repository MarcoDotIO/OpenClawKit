# OpenAI Decisions

Evaluate text and inline images with typed predicate, choice and score questions.

## Overview

OpenClawKit 2026.3.3 adds ``OpenAIDecisionsClient`` in `OpenClawModels` (also exported
by `OpenClawKit` on Apple platforms). It calls OpenAI's official
[`POST /v1/decisions`](https://developers.openai.com/api/reference/resources/decisions/methods/create)
endpoint with an OpenAI Platform API key. The
[Decisions API](https://developers.openai.com/api/docs/guides/decisions) is in public
beta; as of October 7, 2026, the documented model is `gpt-6-luna`.

``OpenAIDecisionRequest`` carries shared evidence and ordered questions.
``OpenAIDecisionResponse`` returns typed answers and usage. Use this client directly
for classification, routing and scoring; `ModelProvider` handles text generation,
tools and streaming through its existing APIs. Choose routing thresholds from
labeled examples and the consequences of mistakes in your application.

## Configure an API key

For local command-line development, put `OPENAI_API_KEY` in an ignored `.env` file
and load it into the host process before launching:

```bash
set -a; . ./.env; set +a
```

```swift
import OpenClawModels

let client = try OpenAIDecisionsClient() // Reads OPENAI_API_KEY from the process environment.
// Or supply a key from your host's secure configuration:
// let client = try OpenAIDecisionsClient(apiKey: key)
```

The library does not read `.env` files automatically or persist API keys. Shipped
apps should supply credentials through their host's secure configuration or server.
``OpenAIDecisionsClient/Options`` lets you set a base URL, organization/project scope
and timeout. An injected ``OpenAICompatibleHTTPTransport`` can implement your own
gateway or provide deterministic test responses.

## Ask typed questions

```swift
let result = try await client.create(OpenAIDecisionRequest(
    input: .text("The customer was charged twice and needs a refund."),
    questions: [
        .predicate(name: "billing_issue", instructions: "Does the customer report a billing issue?"),
        .choice(name: "department", instructions: "Choose the responsible department", choices: [
            .init(value: .string("billing"), description: "Charges, payments or refunds"),
            .init(value: .string("shipping"), description: "Delivery or tracking")
        ]),
        .score(name: "urgency", instructions: "Rate urgency", levels: [
            .init(label: "Low", description: "Informational request"),
            .init(label: "High", description: "Money or access is affected")
        ])
    ],
    safetyIdentifier: "opaque-user-id"
))

for answer in result.answers {
    switch answer {
    case .predicate(let name, let probability):
        print(name ?? "unnamed", probability)
    case .choice(let name, let value, let confidence, let probabilities):
        print(name ?? "unnamed", value, confidence, probabilities)
    case .score(let name, let score, let confidence, let probabilities):
        print(name ?? "unnamed", score, confidence, probabilities)
    case .refusal(let name):
        print("Refused:", name ?? "unnamed")
    }
}
```

Names are optional; supplied names must be unique. Answers are returned in question
order and can also be found with ``OpenAIDecisionResponse/answer(named:)``. A refusal
applies to one question and does not discard the other answers. A score is a
probability-weighted average of zero-based rubric indices and may be fractional.
Choice values may be `.string` or `.bool`; `.string("true")` and `.bool(true)` are
different categories. Choice questions accept 2...255 distinct values.

Batch independent questions against the same input. Send dependent questions in
separate requests after interpreting the earlier answer.

## Include images

```swift
import Foundation

let image = try Data(contentsOf: URL(fileURLWithPath: "product.png"))
let imageResult = try await client.create(OpenAIDecisionRequest(
    input: .messages([
        .init(content: .parts([
            .text("Inspect this product."),
            .image(data: image, mimeType: "image/png", detail: .auto)
        ]))
    ]),
    questions: [.predicate(name: "damaged", instructions: "Does the product have visible physical damage?")]
))
```

Only user messages and `input_text` / `input_image` parts are supported. Images
must be inline base64 image data URLs, with at most 128 images across all messages
in one request. Hosted image URLs, file ids, audio, non-user roles and tools are
unsupported. The input types expose the supported forms, and the client validates
inline images before sending them. Image detail accepts `auto`, `low`, `high` and
`original`.

## Usage and errors

``OpenAIDecisionUsage`` preserves the server's inclusive input-token count, output
and total tokens, cache read/write details and reasoning tokens. Its `modelUsage`
property converts to OpenClaw's uncached-input convention. Decisions currently bills
input only and reports zero output tokens; consult OpenAI's guide for current pricing.

Non-2xx responses throw ``OpenAIDecisionsHTTPError`` with status, code, type,
redacted message, request id and raw `Retry-After` (seconds or an HTTP date).
The client does not retry automatically. Invalid JSON, unknown answer variants
and answers whose count, names or types do not match the request throw
`OpenClawCoreError.unavailable`. Request validation throws
`OpenClawCoreError.invalidConfiguration` before a network call. Cancellation and
URLSession error codes are preserved through the existing transport contract.

## Validate

```bash
swift test --filter OpenAIDecisionsClientTests
set -a; . ./.env; set +a
OPENCLAW_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProviderOpenAIDecisionsTests
```

The offline suite runs in the cross-platform runtime test target on macOS and Linux.
The opt-in live suite makes one small text request with all three question types
and one inline-image request with Boolean choices, and records usage through the
existing live-test ledger. It stays disabled in
normal test runs and CI.
