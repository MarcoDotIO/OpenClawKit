# Ask OpenClaw Share Extension Template

This directory contains a ready-to-wire Share Extension scaffold for the iOS example.

## What it does

- Exposes an `AskOpenClawShareViewController` based on `SLComposeServiceViewController`.
- Writes the shared prompt to an App Group inbox key:
  - suite: `group.io.marcodotio.OpenClawKit`
  - key: `openclaw.share.prompt.inbox`
- The main app consumes this inbox via `SharePromptInbox` during app launch.

## Wiring in Xcode

1. Add a new **Share Extension** target named `AskOpenClawShareExtension`.
2. Point the extension target to this folder's:
   - `AskOpenClawShareViewController.swift`
   - `Info.plist`
3. Configure the App Group capability on both app + extension:
   - `group.io.marcodotio.OpenClawKit`
4. Embed the extension in `OpenClawiOS.app` and run on device/simulator.
