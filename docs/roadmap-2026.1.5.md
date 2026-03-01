# OpenClaw 2026.1.5 Release Roadmap

This roadmap records the implementation train completed for `2026.1.5`.

## Commit Train

1. `test(ios): add runnable iOS unit and UI smoke harness`
2. `fix(ios): bundle example skills deterministically`
3. `feat(ios): wire Telegram deploy controls with secure persistence`
4. `fix(channels): harden Telegram replay handling across restarts`
5. `fix(ios): improve keyboard dismissal ergonomics in forms`
6. `feat(skills): add chat skill picker and bundled sample skills`
7. `feat(ios): add App Intents shortcuts and background continuation`
8. `chore(release): finalize 2026.1.5 docs and release metadata`

## Per-Commit Validation Matrix

Each commit in the train passed the full validation sequence:

1. `swift build -Xswiftc -warnings-as-errors`
2. `Scripts/check-networking-concurrency.sh`
3. `swift test`
4. `./Scripts/build-ios-example.sh`
5. `./Scripts/test-ios-example.sh`

## Release Notes Source of Truth

Release notes for `2026.1.5` are authored in `CHANGELOG.md` and referenced by
the GitHub release metadata.
