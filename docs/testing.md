# Testing Guide

OpenClawKit uses Swift Testing (`import Testing`) for unit, E2E and gated live coverage.

## Run All Tests

```bash
swift test
```

At `2026.3.0` this runs 3,416 tests on macOS (Xcode 27.1, Swift 6.4). The Linux runtime
target runs 403 tests under Swift 6.2.

## Test Structure

- `Tests/OpenClawKitTests`
  - unit-level tests for protocol, core shims, runtime primitives, diagnostics, facade
    helpers, the gateway client, native state, Talk, Watch, ChatUI, ChatStore, App
    Intents, providers (including the stubbed live-provider regressions) and Apple
    Foundation Models
- `Tests/OpenClawKitE2ETests`
  - end-to-end tests across transport/runtime/channels/plugin flow and reconnect lifecycle
- `Tests/OpenClawLinuxRuntimeTests`
  - Linux-focused runtime, provider, gateway, channel, MCP, memory and config-contract
    regressions exercised in CI and Docker
- `Tests/Fixtures/Config`
  - upstream config corpus, doctor and talk contract fixtures, synced with
    `Scripts/sync-config-fixtures.sh`

## Networking Concurrency Gate

Run this before committing networking changes:

```bash
Scripts/check-networking-concurrency.sh
```

This builds the networking-related targets (including `OpenClawMCP`, and on macOS
`OpenClawKit`, `OpenClawChatUI` and `OpenClawAppIntents`) with complete strict
concurrency and warnings as errors.

## Apple Platform Gates

The package builds every product for macOS, iOS, tvOS, watchOS (arm64_32 and arm64)
and visionOS with Xcode 27.1. Logs go to `.build/logs`, DerivedData to
`.build/xcode-<platform>`.

```bash
Scripts/validate-apple-matrix.sh            # static guard rules (fast)
Scripts/typecheck-apple-sdks.sh all         # typecheck OpenClawKit at every SDK floor
Scripts/build-apple-platforms.sh all        # build every product on all five platforms
Scripts/check-apple-weak-links.sh all       # weak-link and runtime-symbol check
```

- `validate-apple-matrix.sh` checks the platform declarations, the example share
  extension artifacts, that 27-only APIs sit behind `#if compiler(>=6.4)`, the
  FoundationModels tvOS/watchOS guards, ChatUI view guards, per-OS availability
  (never `anyAppleOS`) and that every `submitTaskRequest(` call has an
  `@available(iOS 27.0` / `#available(iOS 27.0` gate.
- `typecheck-apple-sdks.sh` emits every module OpenClawKit imports (Protocol, Core,
  NativeState, Gateway, Media, Models, Skills, Agents, Memory, MCP, Plugins, Channels)
  for each minimum-OS triple and typechecks all OpenClawKit sources with
  `-warnings-as-errors`, plus an iOS app-extension pass. It takes a few minutes per
  SDK and does not run SIL diagnostics; the full build stays authoritative.
- `check-apple-weak-links.sh` links the built objects into a probe dylib at the
  deployment floors and fails when a framework newer than the floor is strongly
  linked (27-only frameworks everywhere; FoundationModels, TelephonyMessagingKit,
  ImagePlayground and ManagedApp except on visionOS, where they exist at the floor),
  or when the probe strongly references a 27-only Swift runtime symbol such as
  `swift_task_cancellationShieldPush`/`Pop`. Use `--no-build` to reuse existing
  DerivedData, `<platform> --binary <Mach-O>` to inspect a linked app binary, and
  `OPENCLAW_WEAK_LINK_FRAMEWORKS` / `OPENCLAW_STRONG_SYMBOL_DENYLIST` to override
  the watched lists.

The experimental App Intents model-delegation surface is compiled only with its
package trait:

```bash
swift build --traits ExperimentalAppleModelDelegation -Xswiftc -warnings-as-errors
swift test --traits ExperimentalAppleModelDelegation --filter "PackageSkeletonTests|OpenClawAppIntents"
```

## Example Apps

```bash
Scripts/build-ios-example.sh    # builds Examples/iOS and verifies bundled skills
Scripts/test-ios-example.sh     # unit + UI tests on an available iPhone simulator
Scripts/build-tvos-example.sh   # builds Examples/tvOS
```

Example DerivedData goes to `.build/xcode-example-*` (override with
`OPENCLAW_EXAMPLE_DERIVED_DATA`); `IOS_SIMULATOR_NAME` picks the simulator.

## Generated Sources and Upstream Fixtures

Protocol models, the provider and channel catalogs, the native-state schema and several
test fixtures are derived from the pinned upstream checkout (`.codex/openclaw`, OpenClaw
`v2026.9.6` at `eb377ac59e`). One command runs every `--check`:

```bash
OPENCLAW_UPSTREAM_DIR=.codex/openclaw Scripts/check-upstream-drift.sh
Scripts/check-upstream-drift.sh --allow-missing-upstream   # CI: skips when the checkout is absent
```

It runs `protocol-gen-swift.mjs`, `provider-catalog-gen.mjs`, `channel-catalog-gen.mjs`,
`check-native-state-parity.mjs`, `sync-upstream-gateway-method-fixtures.mjs`,
`sync-upstream-runtime-ext-fixtures.mjs`, `sync-upstream-tool-catalog-fixture.mjs` and
`sync-config-fixtures.sh --check`. Run a generator without `--check` to regenerate, and
review the diff (for the provider catalog, also
`Tests/OpenClawKitTests/ProviderCatalogReferenceFixture.swift`).

## Live Provider Tests

The `LiveProvider*Tests` suites call real provider APIs. They run only when
`OPENCLAW_LIVE_PROVIDER_TESTS=1` is set **and** the provider's key is in the test
process environment; otherwise they report as skipped, so CI and a normal `swift test`
never call a provider. Keep keys in a local, git-ignored `.env` and never commit it.

```bash
set -a; . ./.env; set +a
OPENCLAW_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProvider
```

- Keys: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `XAI_API_KEY`.
- One provider: `--filter LiveProviderOpenAIResponses`, `LiveProviderOpenAIChatCompletions`,
  `LiveProviderAnthropic`, `LiveProviderXAI` or `LiveProviderAgentLoop`.
- Model overrides: `OPENCLAW_LIVE_OPENAI_MODEL` (default `gpt-6-luna`),
  `OPENCLAW_LIVE_ANTHROPIC_MODEL` (default `claude-haiku-4-5`),
  `OPENCLAW_LIVE_XAI_MODEL` (default `grok-4.20-0309-non-reasoning`).
- Anthropic keys that are not scoped to a workspace need `ANTHROPIC_WORKSPACE_ID`
  (or `OPENCLAW_LIVE_ANTHROPIC_WORKSPACE_ID`), sent as the `anthropic-workspace-id`
  header. Without it the API rejects every Messages call with 400 and the tests record
  that exact rejection as a known issue.
- Cost: a full pass is about 48 billed calls and about 4.5k input / 0.8k output tokens,
  well under $0.01 at catalog prices. Output is capped at 64 tokens (160 for tool and
  JSON turns) and there are no retries; the Anthropic thinking tests may use up to about
  1.2k output tokens each.
- Each call prints a `[live-usage] <label> model=… input=… output=… cacheRead=…
  reasoning=… total=…` line. Prompts, bodies and keys are never printed, and failure
  descriptions redact configured keys.
- The stubbed offline regressions (`LiveProviderRegressionTests`) always run.

Status at `2026.3.0`: the final pass ran 64 tests in 6 suites. OpenAI Responses, OpenAI
Chat Completions, xAI and the OpenAI/xAI agent loops passed live; the Anthropic invalid-key
test passed live, and the remaining Anthropic tests wait for a workspace id. The streaming
half of `routerFallsBackFromRejectedKeyToNextProvider` is a known issue:
`ModelRouter.generateStream` does not fall back when a stream fails before its first chunk.

## Other Gated Live Tests

- Apple Foundation Models: `OPENCLAW_LIVE_APPLE_FM=1 swift test --filter AppleFoundationModelsLiveTests`
  (needs Apple Intelligence enabled); add `OPENCLAW_LIVE_APPLE_PCC=1` for Private Cloud
  Compute, which needs Apple's managed entitlement (unsigned test processes get
  `ModelManagerError` 1046, mapped to `notEntitled`, and fall back to on-device).
- Media: `OPENCLAW_LIVE_APPLE_MEDIA=1` (Vision OCR, MusicUnderstanding, MediaIntelligence)
  and `OPENCLAW_LIVE_SPEECH=1` (missing speech assets count as a skip). The first Vision
  run on a machine can take about 80 s.
- CoreAI: `OPENCLAW_COREAI_MODEL_PATH=<model.aimodel>`.

## Recommended Local Validation Sequence

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/lint-swift.sh` (Sources, Tests, Examples and `Package.swift`)
3. `Scripts/check-networking-concurrency.sh`
4. `swift test`
5. `Scripts/build-docs-site.sh`
6. `Scripts/validate-apple-matrix.sh`
7. `Scripts/typecheck-apple-sdks.sh all`
8. `Scripts/build-apple-platforms.sh all`
9. `Scripts/check-apple-weak-links.sh all`
10. `Scripts/build-ios-example.sh`
11. `Scripts/test-ios-example.sh`
12. `Scripts/build-tvos-example.sh`
13. `Scripts/check-upstream-drift.sh` (with the upstream checkout)
14. The Linux Swift 6.2 gate below, for cross-platform module changes

Clean up large build folders afterwards with `rm -rf .build/xcode-*`.

## Linux Runtime Validation

The repo CI runs the Linux runtime gate on Ubuntu with Swift 6.2. The cross-platform
modules must stay Swift 6.2 compatible: no Swift 6.3/6.4-only syntax outside
`#if compiler(>=6.4)`, Apple frameworks only behind `#if canImport`, and
FoundationNetworking where `URLSession` is used. To catch Linux-only failures before
pushing, run the same scripts in Docker. The named volume keeps the Linux `.build` separate
from the macOS one:

```bash
docker run --rm -v "$PWD:/workspace" -v openclawkit-linux-build:/workspace/.build \
  -w /workspace swift:6.2 bash -c \
  'Scripts/build-linux-runtime.sh && Scripts/check-networking-concurrency.sh && Scripts/test-linux-runtime.sh'
```

## Documentation Validation

The public docs site is generated with Swift-DocC on macOS.

```bash
Scripts/build-docs-site.sh
```

The script builds every first-party module's archive (including `OpenClawMCP`,
`OpenClawNativeState`, `OpenClawChatStore` and `OpenClawAppIntents`), merges them, and
fails if the static site does not contain `index.html` and the
`documentation/openclawkit` entry point expected by GitHub Pages.
