# Apple Intelligence

Run agents on Apple Foundation Models, Private Cloud Compute and on-device ML.

## Overview

`FoundationModelsProvider` (OpenClawModels) is the `apple-fm` provider. It calls
FoundationModels in process (there is no helper binary) and follows upstream OpenClaw's
`apple-fm` extension for identity, facts and error copy. On the 27 SDKs it adopts the
FoundationModels 27 surface: reasoning levels, tool-calling and sampling modes, image
input, usage, Private Cloud Compute, and the Vision and Spotlight tools.

## Identity

| Ref | Meaning |
| --- | --- |
| `apple-fm/system` | The on-device system model (`FoundationModelsProvider.systemModelID`). |
| `apple-fm/private-cloud-compute` | Private Cloud Compute (alias `apple-fm/pcc`). SDK-only, not in upstream. |

`foundation` and `apple-foundation-default` are accepted as aliases, and responses
report model id `system` or `private-cloud-compute`. `ModelRouter` does not resolve
aliases, so route with the constants:

```swift
import OpenClawKit

let router = ModelRouter()
await router.register(FoundationModelsProvider())
let response = try await router.generate(ModelGenerationRequest(
    sessionKey: "main",
    prompt: "Summarize my day in two sentences.",
    providerID: FoundationModelsProvider.providerID,
    modelID: FoundationModelsProvider.systemModelID))
```

`FoundationModelsProvider.runtimeAvailability()` reports why the model cannot run, with
upstream wording (for example "Enable Apple Intelligence in System Settings, then retry
setup."). `systemModelFacts()` and `facts(target:)` return the variant, context window
and capabilities; `eligibleForUtilityRole(facts:)` applies upstream's 8,192-token
utility-role rule.

## Tools, structured output and streaming

`apple-fm` implements model contract v2:

- Transcript replay: instructions, prompts, responses, reasoning (27), tool calls, tool
  outputs and labeled images.
- Tool calling is host-owned by default (`FoundationModelsToolExecutionMode.proposeOnly`):
  the first tool call stops generation and returns with stop reason `toolUse`, and the
  agent loop approves and runs it. `.executeInProcess(_:)` lets the session run tools
  itself through an executor.
- JSON-Schema structured output is converted with upstream's keyword rules and
  re-validated on the host (patterns and lengths are enforced there).
- Streaming emits real deltas. With tools or a schema, output is published only after
  completion.
- Requests can be cancelled by token (`cancelGeneration(token:)`); a cancelled request
  never publishes tool calls.
- Image or binary attachments need a vision-capable model. Without one the provider
  throws "Only text content is supported for user and tool-result messages" and the
  router falls back.

```swift
let provider = FoundationModelsProvider(options: FoundationModelsProviderOptions(
    fallbackToOnDevice: true,
    tools: FoundationModelsToolOptions(execution: .proposeOnly, visionTools: true)))
```

Failures throw `FoundationModelsError` with stable codes (`context_overflow`,
`rate_limited`, `guardrail`, `refusal`, `unsupported_capability`, `timeout`,
`invalid_structured_output`, …). The embedded agent runtime compacts and retries once on
`context_overflow`, records tools the provider executed in process
(`ModelGenerationResponse.executedToolCalls`), and switches on Tool Search for
small-context models.

## Private Cloud Compute

`apple-fm/private-cloud-compute` runs on Apple's Private Cloud Compute (OS 27):

- It requires Apple's managed Private Cloud Compute entitlement. Without it requests fail
  with `ModelManagerError` 1046, which the SDK maps to `FoundationModelsErrorMapper.notEntitled`
  (code `unavailable`); with `fallbackToOnDevice` (the default) the provider answers with
  the on-device model instead.
- `FoundationModelsProvider.privateCloudQuota()` returns a quota snapshot, and
  `presentPrivateCloudQuotaIncreaseSuggestion()` shows the system's quota-increase offer.
- It is the only Foundation Models route on watchOS 27, where `SystemLanguageModel` is
  unavailable.

## Vision and Spotlight tools

On OS 27 the provider offers Vision's OCR and barcode tools for image requests
(`visionTools`), and an opt-in Spotlight search tool
(`FoundationModelsToolOptions.spotlightSearch`, Apple silicon only).
`AppleIntelligenceTools.visionTools()` and `spotlightSearchTool(options:)` return the
tools for your own `LanguageModelSession`. The memory module offers the same search as
the `spotlight_search` agent tool; pass one `SpotlightMemoryIndexDelegate` to
`installMemory(spotlightIndexDelegate:)` and `FoundationModelsSpotlightSearchOptions` so
both see the same index. Spotlight queries are bounded by a 3-second non-joining timeout
and fall back to the in-memory mirror.

## Use any provider as a LanguageModel

`OpenClawLanguageModel` (OS 27) is a FoundationModels `LanguageModel` backed by an
OpenClaw provider, so Foundation Models code (`LanguageModelSession`, `@Generable`,
`Tool`) can target Claude, GPT, Gemini or a `ModelRouter` route:

```swift
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels

if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
    let model = OpenClawLanguageModel(provider: anthropicProvider, modelID: "claude-opus-5")
    let session = LanguageModelSession(model: model)
    let answer = try await session.respond(to: "Draft a release note.")
}
#endif
```

OpenClawAgents bridges agent tools into FoundationModels sessions
(`FoundationModelsAgentToolAdapter`, `OpenClawAgentProfile`) and
`EmbeddedAgentRuntime.makeFoundationModelsSession(agentID:…)` builds a session wired to
the agent's tools and hooks.

## On-device media and CoreAI

For models that cannot read media, `MediaPipeline.applyMediaUnderstanding(_:policy:)`
turns images into Vision OCR/barcode text, videos into MediaIntelligence key frames plus
a summary line, and audio into SpeechAnalyzer transcripts. Failures never throw; the
media passes through with the reason in `issues`. The `music_analyze` tool reports key,
BPM, structure, loudness, pace and instruments with MusicUnderstanding. CoreAI
`.aimodel` files run through `CoreAIModelRuntime`; `CoreAILocalModelEngine` needs a
caller-supplied tokenizer and `CoreAIEmbeddingProvider` produces text embeddings.

## Availability

| Feature | iOS / macOS / visionOS | watchOS | tvOS | Linux |
| --- | --- | --- | --- | --- |
| `apple-fm/system` | 26+ | Unavailable (no `SystemLanguageModel`) | Unavailable (`frameworkUnavailable`) | Identity, facts and schema helpers only |
| FoundationModels 27 surface, PCC, `OpenClawLanguageModel` | 27 | 27 (PCC only) | Compiled out | Compiled out |
| Vision OCR tool | 27 | Not available | — | — |
| Spotlight search tool | 27, Apple silicon | — | — | — |
| Vision OCR (media) | iOS 18 / macOS 15 / visionOS 2 (tvOS 18) | Barcodes on 27 | tvOS 18 | Reports unsupported |
| MediaIntelligence video | 27 (also tvOS 27) | — | 27 | Reports unsupported |
| MusicUnderstanding, CoreAI | 27 | 27 | 27 | Reports unsupported |
| SpeechAnalyzer transcription | 26 | — | 26 | Reports unsupported |

Every 27-only API is behind `#if compiler(>=6.4)` and per-OS `@available`, so
FoundationModels, `_Vision_FoundationModels`, `_CoreSpotlight_FoundationModels`,
CoreAI, MediaIntelligence and MusicUnderstanding are weak-linked at the package floors
(`Scripts/check-apple-weak-links.sh`). Apps with iOS 17–26 deployment targets launch on
older systems.

## Live tests

```bash
OPENCLAW_LIVE_APPLE_FM=1 swift test --filter AppleFoundationModelsLiveTests
OPENCLAW_LIVE_APPLE_PCC=1 OPENCLAW_LIVE_APPLE_FM=1 swift test --filter AppleFoundationModelsLiveTests
OPENCLAW_LIVE_APPLE_MEDIA=1 swift test --filter AppleMediaUnderstandingLiveTests
```

They need Apple Intelligence enabled; PCC also needs the managed entitlement.
