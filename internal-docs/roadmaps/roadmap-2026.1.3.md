# 2026.1.3 Aggressive Parity Issue Map

This document maps the 2026.1.3 implementation train to GitHub issues and intended commit closures.

## Issue Mapping

- Step 1: Issue scaffolding and scope lock -> #4
- Step 2: Model contracts for streaming/cancellation/fallback routing -> #5
- Step 3: LLMFarm-backed local model provider integration -> #6
- Step 4: Skills runtime parity expansion -> #7
- Step 5: Channel runtime parity enhancements -> #8
- Step 6: Diagnostics and usage metrics pipeline -> #9
- Step 7: iOS example major expansion -> #10
- Step 8: Test and CI hardening for parity changes -> #11
- Step 9: Release packaging, docs refresh, and 2026.1.3 release flow -> #12

## Commit Closure Policy

- One plan step equals one commit.
- Each commit message must include a closing clause for the mapped issue (for example, `Closes #5`).
- Each commit must pass:
  - `swift build` with zero warnings
  - `Scripts/check-networking-concurrency.sh`
  - `swift test`
  - `./Scripts/build-ios-example.sh` when iOS-app-facing code is touched

