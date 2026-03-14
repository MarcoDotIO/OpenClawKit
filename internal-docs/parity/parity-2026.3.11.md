# 2026.3.11 SDK + Control-Plane Parity Manifest

This document locks the parity target for the `2026.2.3` OpenClawKit release
train.

## Baseline Scope

- **Upstream parity reference:** pinned `.cursor/openclaw` snapshot at
  `62a71361a98d87b2b35a45d0f5ab7627eeea0916`
- **Swift implementation source of truth:** `Sources/`
- **Release target:** `2026.2.3`
- **Scope lock:** SDK plus control-plane parity only. TS-only CLI, TUI, web,
  and dashboard application surfaces remain out of scope for this train.

## Release Rules

Each implementation step must land as exactly one commit.

Before creating that commit, all of the following must be true:

1. `swift build -Xswiftc -warnings-as-errors` passes without project warnings.
2. All previously passing tests still pass.
3. Any tests added or updated for the step pass.
4. The step includes targeted regression coverage for the new codepaths it
   introduces, with broader path coverage added where the change warrants it.

No required validation, warning cleanup, or critical regression test may be
deferred to a later commit.

## 2026.2.3 Parity Workstreams

- Session state, thinking, and reasoning parity.
- In-process gateway control-plane parity for agent, sessions, models, skills,
  secrets, and `browser.request`.
- `llm-task` and agent/runtime cleanup parity.
- Exec allowlist and process-safety parity.
- Media fetch/store/handle parity.
- Channel hardening parity, including BlueBubbles/iMessage and Telegram restart
  scoping.

## Checked-In Swift Fixtures

Parity verification for this train stays inside the Swift repo:

- `Tests/OpenClawKitTests/ProviderCatalogReferenceFixture.swift` keeps the
  provider/auth snapshot assertions local to the package tests.
- `Tests/OpenClawKitTests/ControlPlaneParityFixtures.swift` captures the
  session-control, gateway payload, `llm-task`, thinking-alias, and channel-edge
  fixture data used by the parity regression suites.

The runtime and test gate must not read `.cursor/**` directly.

## Release Finish

After the final implementation commit passes the full validation gate:

1. update `CHANGELOG.md` with the final `2026.2.3` notes
2. tag the release commit as `2026.2.3`
3. create or update the GitHub release from that exact commit
4. push the branch and the tag
