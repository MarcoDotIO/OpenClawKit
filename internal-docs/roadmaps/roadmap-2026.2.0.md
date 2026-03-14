# Roadmap 2026.2.0

This document tracks the 2026.2.0 implementation train using the
`one step = one commit` release discipline.

## Commit Train

1. `c1-config-event-schema` - runtime config + replay event schema
2. `c2-replay-store` - append-only replay store + compaction/recovery
3. `c3-runtime-event-emission` - deterministic runtime/channel replay emission
4. `c4-replay-engine-sdk-api` - replay engine + SDK replay APIs
5. `c5-secure-enclave-ledger` - signed replay ledger primitives
6. `c6-instruments-timeline` - timeline sink + diagnostics export
7. `c7-adaptive-router-state` - adaptive routing policy state/scoring
8. `c8-adaptive-router-loop` - diagnostics-driven router feedback loop
9. `c9-wasm-skill-runtime` - WASM skill runtime integration
10. `c10-permissioned-connectors` - personal-data connector permissions kit
11. `c11-intent-graph-sdk` - intent graph protocol/runtime/SDK surface
12. `c12-dynamic-app-intents` - intent-graph-aware iOS intents/shortcuts
13. `c13-live-activities` - iOS Live Activities run-status integration
14. `c14-proactive-automation` - automation rules + background execution hooks
15. `c15-multimodal-mode` - attachment-first multimodal runtime/channel/iOS flow
16. `c16-swiftdata-cloudkit-memory` - memory graph bridge + migration support
17. `c17-share-extension-apple-matrix` - Ask OpenClaw share scaffold + Apple matrix CI
18. `c18-readme-release-finalize` - README/docs/changelog finalization + release/tag

## Required Validation Gate (Per Commit)

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/check-networking-concurrency.sh`
3. `swift test`
4. `./Scripts/build-ios-example.sh`
5. `./Scripts/test-ios-example.sh`
6. `Scripts/validate-apple-matrix.sh --platform macos`
7. `Scripts/validate-apple-matrix.sh --platform ios`
