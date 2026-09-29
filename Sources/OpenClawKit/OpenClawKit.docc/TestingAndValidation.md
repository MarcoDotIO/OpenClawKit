# Testing and Validation

The package ships with unit, end-to-end, Apple-platform, Linux runtime and gated live
validation paths. The same scripts used locally are also consumed by CI.

## Recommended Local Gate

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/lint-swift.sh
Scripts/check-networking-concurrency.sh
swift test
Scripts/build-docs-site.sh
```

Build with Xcode 27.1 (Swift 6.4). Its own toolchain is required to use the 27 SDKs;
do not point `swift` at a separately installed Swift 6.2 toolchain on macOS.

## Apple Platforms

```bash
Scripts/validate-apple-matrix.sh            # static guard rules
Scripts/typecheck-apple-sdks.sh all         # typecheck OpenClawKit at every SDK floor
Scripts/build-apple-platforms.sh all        # every product on all five platforms
Scripts/check-apple-weak-links.sh all       # weak links and 27-only runtime symbols
Scripts/build-ios-example.sh
Scripts/test-ios-example.sh
Scripts/build-tvos-example.sh
```

- `validate-apple-matrix.sh` enforces the platform guards: 27-only APIs behind
  `#if compiler(>=6.4)`, per-OS `@available` (never `anyAppleOS`), the FoundationModels
  tvOS and watchOS guards, and an iOS 27 availability gate for every
  `submitTaskRequest(` call.
- `check-apple-weak-links.sh` links the built objects at the deployment floors and fails
  when a framework newer than the floor is strongly linked, or when a 27-only Swift
  runtime symbol such as `swift_task_cancellationShieldPush` is strongly referenced
  (the reason the SDK does not use `withTaskCancellationShield`). Pass
  `<platform> --binary <Mach-O>` to check your own linked app.
- The experimental model-delegation surface builds only with its trait:
  `swift build --traits ExperimentalAppleModelDelegation -Xswiftc -warnings-as-errors`.

## Linux in Docker

The cross-platform modules must keep building with Swift 6.2. Use a named volume for
`.build` so the Linux build does not mix with the macOS one:

```bash
docker run --rm -v "$PWD:/workspace" -v openclawkit-linux-build:/workspace/.build \
  -w /workspace swift:6.2 bash -c \
  'Scripts/build-linux-runtime.sh && Scripts/check-networking-concurrency.sh && Scripts/test-linux-runtime.sh'
```

## Generated Sources

Protocol models, the provider and channel catalogs, the native-state schema and several
fixtures are derived from the pinned upstream checkout (OpenClaw `v2026.9.6` at
`eb377ac59e`):

```bash
OPENCLAW_UPSTREAM_DIR=.codex/openclaw Scripts/check-upstream-drift.sh
```

## Live Tests

Live suites call real services and never run in CI. Each one runs only when its opt-in
variable is set:

```bash
set -a; . ./.env; set +a
OPENCLAW_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProvider
OPENCLAW_LIVE_APPLE_FM=1 swift test --filter AppleFoundationModelsLiveTests
```

The provider suites need `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` or `XAI_API_KEY` in the
test process environment. A full provider pass is about 48 billed calls, well under
$0.01 at catalog prices. Anthropic keys that are not scoped to a workspace also need
`ANTHROPIC_WORKSPACE_ID`, which is sent as the `anthropic-workspace-id` header.

## CI and Docs Publishing

The CI workflow runs SwiftLint, the upstream drift checks, the Linux Swift 6.2 build and
tests, the macOS strict build and tests, the five-platform matrix (typecheck, build and
weak-link check), a build with the `ExperimentalAppleModelDelegation` trait, and both
example apps. The documentation workflow builds this Swift-DocC site on pull requests
and deploys it to GitHub Pages after successful pushes to `main`.
