# Testing Guide

OpenClawKit uses Swift Testing (`import Testing`) for both unit and E2E coverage.

## Run All Tests

```bash
swift test
```

## Test Structure

- `Tests/OpenClawKitTests`
  - unit-level tests for protocol, core shims, runtime primitives, diagnostics, facade helpers
- `Tests/OpenClawKitE2ETests`
  - end-to-end tests across transport/runtime/channels/plugin flow and reconnect lifecycle

## Networking Concurrency Gate

Run this before committing networking changes:

```bash
Scripts/check-networking-concurrency.sh
```

This enforces strict concurrency diagnostics for networking-related targets.

## API Key Dependent E2E Workflows

Some integration-style E2E workflows may require provider keys:

- `OPENAI_API_KEY`
- `GEMINI_API_KEY`

Set these in local `.env` (ignored by git) when running provider-backed E2E scenarios.
Never commit `.env`.

## Recommended Local Validation Sequence

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/check-networking-concurrency.sh`
3. `swift test`
4. `./Scripts/build-ios-example.sh`
5. `./Scripts/test-ios-example.sh`
6. `Scripts/validate-apple-matrix.sh --platform macos`
7. `Scripts/validate-apple-matrix.sh --platform ios`

## 2026.2.0 Reliability + Platform Coverage Highlights

- Replay/diagnostics reliability:
  deterministic replay sequence tests, replay store compaction/recovery, and
  SDK replay query filtering coverage.
- Router/telemetry reliability:
  adaptive routing policy + closed-loop diagnostics tests for provider scoring
  behavior under runtime feedback.
- Skills/runtime reliability:
  WASM execution tests plus connector-permission policy coverage across allow/deny paths.
- Apple integration reliability:
  intent-graph App Intents tests, Live Activity status checks, proactive
  automation background hook tests, and multimodal iOS/UI/runtime assertions.
- Memory reliability:
  SwiftData+CloudKit-ready memory graph migration/config tests.
- CI platform coverage:
  Apple matrix contract validation in `Scripts/validate-apple-matrix.sh`
  (platform declarations, share-extension scaffold, iOS 26 API guard checks).
