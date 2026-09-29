@_exported import OpenClawKit

// Localization (2026.3.0 decision): ChatUI strings stay English source literals written as
// `String(localized:)` / `Text("…")` without a `bundle:` argument, exactly like upstream OpenClaw 2026.9.6. They
// resolve against the host app's main bundle, so a host localizes the chat by adding the same keys to its own
// string catalog; without one, English shows. The package declares no `defaultLocalization` and ships no
// `Localizable.xcstrings`, so there is no SDK-owned catalog or `bundle: .module` routing yet. Adding one later
// is additive: route the literals through a `.module` helper once Package.swift sets `defaultLocalization`.
