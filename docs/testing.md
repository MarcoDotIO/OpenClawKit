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

## 2026.1.5 Reliability + Platform Coverage Highlights

- iOS unit/UI harness coverage for deploy/chat/models keyboard behavior, Telegram
  deploy controls, and chat skill-picker visibility.
- Telegram adapter replay safety coverage for persisted offsets and duplicate
  update handling across restart scenarios (unit + E2E).
- Skill coverage expansion for bundled iOS sample skills and hyphenated explicit
  invocation paths.
- Deterministic iOS skills bundling verification in build validation
  (`Scripts/verify-ios-skills-bundle.sh`).
