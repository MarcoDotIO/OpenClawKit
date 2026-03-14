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
- `Tests/OpenClawLinuxRuntimeTests`
  - Linux-focused runtime, provider, gateway, and channel regressions exercised in CI and Docker

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
- `ANTHROPIC_API_KEY`
- `XAI_API_KEY`

Set these in local `.env` (ignored by git) when running live provider-backed scenarios.
Never commit `.env`.

## Recommended Local Validation Sequence

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/lint-swift.sh`
3. `Scripts/check-networking-concurrency.sh`
4. `swift test`
5. `Scripts/build-docs-site.sh`
6. `./Scripts/build-ios-example.sh`
7. `./Scripts/test-ios-example.sh`
8. `./Scripts/build-tvos-example.sh`
9. `Scripts/validate-apple-matrix.sh --platform macos`
10. `Scripts/validate-apple-matrix.sh --platform ios`

## Linux Runtime Validation

The repo CI runs the Linux runtime gate on Ubuntu. To catch Linux-only failures
before pushing, run the same scripts in Docker:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 Scripts/build-linux-runtime.sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 Scripts/check-networking-concurrency.sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 Scripts/test-linux-runtime.sh
```

## Documentation Validation

The public docs site is generated with Swift-DocC on macOS.

```bash
Scripts/build-docs-site.sh
```

The script fails if the static site does not contain `index.html` and the
`documentation/openclawkit` entry point expected by GitHub Pages.
