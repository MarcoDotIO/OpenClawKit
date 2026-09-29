# App Intents and System Integration

Expose OpenClaw to Siri and Shortcuts and adopt the Apple 27 system frameworks.

## Overview

OpenClawKit 2026.3.0 integrates with the system through opt-in, availability-gated
helpers. Every 27-only API sits behind `#if compiler(>=6.4)` and per-OS `@available`,
so apps with iOS 17 / macOS 14 deployment targets keep launching on older systems
(verified with `Scripts/check-apple-weak-links.sh`).

| Integration | Where | Availability |
| --- | --- | --- |
| App Intents entities and intents | `OpenClawAppIntents` product | All Apple platforms; OS 27 extras |
| StateReporting | ``OpenClawSystemState`` | iOS, macOS, tvOS, watchOS, visionOS 27 (opt-in) |
| Now Playing | ``OpenClawNowPlaying`` | NowPlaying `MediaSession` on 27, `MPNowPlayingInfoCenter` before |
| Background task submission | ``OpenClawBackgroundTasks`` | iOS and tvOS; async on 27 |
| Run progress | ``OpenClawRunProgress`` | Foundation `ProgressManager` on 27, `Progress` before |
| TrustInsights approval friction | ``OpenClawApprovalGate`` | iOS 27 |
| LinkSecurity | OpenClawChatUI | Flagging on all 27 platforms; UI on iOS, macOS, visionOS |
| ScreenCaptureKit `screen.record` | `ScreenCaptureKitRecorder` | iOS and visionOS 27 |
| Live Activities | `OpenClawActivityAttributes`, `OpenClawAgentRunActivityAttributes` | iOS |

## App Intents

The `OpenClawAppIntents` product ships:

- `OpenClawSessionAppEntity` and `OpenClawAgentAppEntity` with queries;
- `AskOpenClawIntent`, `AbortOpenClawRunIntent` and `StartOpenClawTalkIntent`
  ("Start Live Voice");
- on OS 27, `RunOpenClawTaskIntent`, a cancellable long-running background intent with
  progress that aborts the run when cancelled;
- intent hosts: `EmbeddedOpenClawIntentHost` (in-process runtime) and
  `GatewayOpenClawIntentHost` (`sessions.list`, `agents.list`, `chat.send`, `chat.abort`
  over any `GatewayRequestSending`).

Set it up in three steps:

1. Link `OpenClawAppIntents` and register a host once, before the system can run an
   intent (for example in the `App` initializer).
2. Declare an app `AppIntentsPackage` that includes `OpenClawAppIntentsPackage`. With
   Xcode 27.1, linking the product already merges the SDK's App Intents metadata into
   the app (verified at an iOS 17 deployment target); the package keeps older toolchains
   and re-exporting frameworks working.
3. Keep the app's single `AppShortcutsProvider` in the app target and list the SDK
   intents there.

```swift
import AppIntents
import OpenClawAppIntents
import OpenClawKit

@main
struct MyApp: App {
    init() {
        OpenClawAppIntents.configure(host: EmbeddedOpenClawIntentHost(runtime: runtime))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

struct MyAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [OpenClawAppIntentsPackage.self] }
}

struct MyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOpenClawIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask OpenClaw",
            systemImageName: "message")
    }
}
```

Intents resolve the host through `OpenClawAppIntents.host` rather than `@AppDependency`,
which fatal-errors outside the App Intents perform flow. `RunOpenClawTaskIntent` runs
only in the app process. If the runtime is created later than launch, register a small
forwarding host at launch (the example apps do this with `ExampleIntentHost`).

On OS 27, OpenClaw errors adopt `CustomAppIntentErrorConvertible`, session entities adopt
`OwnershipProvidingEntity`, queries declare execution targets, and notification or Now
Playing content can be linked to a session entity with `linkOpenClawSession(_:)`.
`OpenClawTalkRelevanceCoordinator` publishes the active talk session to relevant
entities.

### Experimental model delegation

With the default-off `ExperimentalAppleModelDelegation` package trait,
`OpenClawModelDelegationIntent` makes OpenClaw a delegated model for Siri, Writing Tools
and Shortcuts on iOS, macOS and visionOS 27. It is built on the underscored
`_ModelDelegationIntent` API, which may change or disappear in any SDK update:

```swift
.package(url: "https://github.com/MarcoDotIO/OpenClawKit.git", from: "2026.3.0",
         traits: [.defaults, "ExperimentalAppleModelDelegation"])
```

`OpenClawAppIntents.isExperimentalModelDelegationEnabled` reports whether the build
includes it.

## StateReporting

Reporting is opt-in:

```swift
OpenClawSystemState.isEnabled = true
let sink = OpenClawSystemState.diagnosticSink(forwardingTo: await pipeline.sink())
let runtime = EmbeddedAgentRuntime(diagnosticsSink: sink)
```

- The SDK owns the `ai.openclaw.gateway`, `ai.openclaw.node.invoke`,
  `ai.openclaw.agent.run`, `ai.openclaw.talk` and `ai.openclaw.config` domains, with one
  metadata type per domain. Never call `StateReporter.reporter(for:)` with these names
  yourself: StateReporting traps on a type mismatch.
- The gateway channel, node session and talk report their state when enabled (or when
  you pass a `stateReporter`); `OpenClawSDK.loadConfigRuntime(fromOpenClawJSON:)`
  reports config health; the diagnostics sink reports agent runs.
- Metadata never contains prompt or message text, tokens, URLs, hosts or phone numbers.
  Session keys are reported as a 16-hex SHA-256 prefix. Volatile updates are limited to
  one per second per domain. Overlapping agent runs share one domain (last writer wins).

## Now Playing

```swift
let publisher = OpenClawNowPlaying.makeSystemPublisher()          // app targets
let extensionPublisher = OpenClawNowPlaying.makeExtensionSafePublisher() // app extensions
```

The system publisher uses NowPlaying `MediaSession` on OS 27 and `MPNowPlayingInfoCenter`
before; `MediaSession` is unavailable in iOS app extensions, so extensions must use the
extension-safe publisher. Talk speech publishes live metadata, and ChatUI media playback
uses the extension-safe publisher unless you call
`OpenClawChatMediaPlayback.setNowPlayingPublisher(OpenClawNowPlaying.makeSystemPublisher())`.

## Background tasks

``OpenClawBackgroundTasks`` returns every scheduler error instead of dropping it with
`try?`. On iOS/tvOS 27 it uses the async `BGTaskScheduler.submitTaskRequest(_:)`:

```swift
let refresh = BGAppRefreshTaskRequest(identifier: "com.example.refresh")
refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
if let error = await OpenClawBackgroundTasks.submit(refresh) {
    log("refresh not scheduled: \(OpenClawBackgroundTasks.SubmissionFailure(error))")
}

if #available(iOS 26.0, *) {
    let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Agent run", subtitle: "Working")
    request.strategy = .fail                        // falls back to .queue when it cannot start now
    _ = await OpenClawBackgroundTasks.submitContinuedProcessing(request)
}
```

Call the helpers from a background context; the scheduler documents that submission
must not run on the main thread. If you call `submitTaskRequest(_:)` directly, keep it
behind `#if compiler(>=6.4)` and an iOS 27.0 availability check;
`Scripts/validate-apple-matrix.sh` enforces that.

## Run progress

``OpenClawRunProgress`` models an agent run's progress (queued, model call, tools,
finalize). On OS 27 it is backed by Foundation `ProgressManager`; attach it to a legacy
`Progress` (`LongRunningIntent.progress`, `BGContinuedProcessingTask.progress`) with
`attach(to:)`, and feed it with `record(_:)` from runtime diagnostics.

## TrustInsights approval friction

``OpenClawApprovalGate`` evaluates coaching-risk signals before sensitive operations
(approving a device pairing, rotating a device token, resolving an exec approval). On
iOS 27, `TrustInsightsApprovalSignals` supplies the signals; elsewhere the gate uses
`NoopApprovalTrustSignals`. The gate is local-only and never prompts implicitly; the app
decides how much friction to add for each `OpenClawApprovalFriction` level.

## LinkSecurity, data detection and suggested actions

OpenClawChatUI flags links from untrusted sources (tool results, inbound channel
messages) with LinkSecurity on OS 27 and asks for confirmation before opening a flagged
link. Assistant text gets system data detection on iOS/visionOS 27 (opt out with
`.openClawChatDataDetection(false)`), and Apple Intelligence suggested actions appear
under the latest inbound message when you opt in with `.openClawSuggestedActions(true)`.

## Permissions and local network

`OpenClawPermissionsSnapshot.current()` reads permission status without prompting, and
`OpenClawLocalNetworkAccessGate` defers the local-network prompt until gateway setup.
The SDK never prompts at initialization: request Contacts, Calendar and Reminders on
first use, and request notification authorization from your settings UI.

## Related Symbols

- ``OpenClawSystemState``
- ``OpenClawNowPlaying``
- ``OpenClawBackgroundTasks``
- ``OpenClawRunProgress``
- ``OpenClawApprovalGate``
- ``OpenClawPermissionsSnapshot``
