# Talk and Watch

Add live voice over the gateway relay and connect an Apple Watch.

## Overview

OpenClawKit 2026.3.0 implements the protocol-v4 Talk surface and the upstream
iPhone–Watch companion contracts. Neither depends on ElevenLabsKit: cloud speech stays on
the gateway, and the SDK falls back to on-device voices.

## Talk

``TalkGatewayClient`` wraps the Talk methods (`talk.catalog`, `talk.config`, `talk.mode`,
`talk.session.*`, `talk.client.*`, `talk.voice.*`, `talk.speak`, `tts.speak`) over any
`TalkGatewayRequesting` connection, such as a ``GatewayNodeSession``:

```swift
let talk = TalkGatewayClient(session)
let config = try await talk.configSnapshot(defaultProvider: "elevenlabs", defaultSilenceTimeoutMs: 700)
```

Once its `isCurrent` closure reports that the originating connection is gone, the client
throws `CancellationError`, so cleanup never goes out on a new connection.

### Realtime relay sessions

`RealtimeTalkRelaySession` (iOS, macOS, visionOS) streams PCM16 microphone audio through
the gateway relay, plays the reply with `RealtimePCMStreamingAudioPlayer`, supports
barge-in, output cancellation, agent tool calls, steering and voice switching, and
reports a typed route-lost error for fallback. Bind it to the current route:

```swift
if let route = await session.currentRoute() {
    let transport = RealtimeTalkRelayTransport.gatewayNodeSession(session, route: route)
    // Create the RealtimeTalkRelaySession with this transport and
    // AVAudioEngineRealtimeTalkAudioCapture().
}
```

- Realtime Talk over the relay needs the `operator.talk` scope and a gateway whose
  realtime provider uses OpenAI Platform API-key auth. `talk.config` with secrets needs
  `operator.talk.secrets`.
- Relay sessions omit `model`, so the gateway default applies; client-owned sessions
  default OpenAI to `gpt-realtime-2.1` (`TalkRealtimeDefaults.openAIModel`).
- The host owns `AVAudioSession` configuration (`.playAndRecord`, mode `.voiceChat` on
  iOS and visionOS). `TalkAudioSessionController` only activates, deactivates and
  observes; `applyAudioSessionEvent` pauses and resumes the microphone on interruptions.
- Route `openclaw://talk/start` (`DeepLinkRoute.talkStart`) to your live-voice controller;
  `StartOpenClawTalkIntent` uses the same entry point.

### Speech output

`TalkSpeechFallbackChain` speaks replies through gateway `talk.speak` and falls back to
`TalkSystemSpeechSynthesizer` (per-language watchdogs; a cancelled caller no longer stops
the utterance already playing). Custom `PCMStreamingAudioPlaying` players must return
`StreamingPlaybackResult(finished: false, interruptedAt: …)` when stopped so the chain
does not also play the system voice. Talk speech publishes Now Playing metadata through
``OpenClawNowPlaying``.

`OpenClawAudioDownmix`, `TalkWakeWordMatcher` (accepts trigger-only phrases) and
`TalkVoiceWakeRoute` help build wake-word and push-to-talk flows. On OS 27 capture and
playback use the Sendable read-only PCM buffers from AVFAudio 27.

## Watch

### Companion messages

The `watch.*` vocabulary (app snapshots and commands, exec approval prompts and
resolutions, chat completions, semantic app statuses) is available as typed messages.
The SDK does not import WatchConnectivity: encode and decode with
`OpenClawWatchMessageCodec` and send the dictionaries yourself.

```swift
let payload = try OpenClawWatchMessageCodec.encode(message)
WCSession.default.sendMessage(payload, replyHandler: nil)

if let received = try OpenClawWatchMessageCodec.decode(incoming) {
    handle(received)
}
```

`applicationContext(for:merging:)` builds the dictionary for
`updateApplicationContext`. iPhone relay hosts can use `OpenClawWatchUnavailableReason`
for `WATCH_UNAVAILABLE` node errors and `OpenClawWatchNotifyParams.normalized()` for
`watch.notify`.

### Durable chat delivery

`OpenClawWatchChatDeliveryStore` is a watch-owned SQLite journal in its own
`watch-chat-delivery.sqlite` file (never `state/openclaw.sqlite`) that resends
unacknowledged chat messages without duplicates. Record receipts with
`record(_:nowMs:)` and send back the returned acknowledgement. It survives app
termination, not power loss.

### Direct Apple Watch node

`OpenClawWatchNodeClient` makes an Apple Watch its own gateway node over signed HTTPS
long-poll (`/api/nodes/watch/*`) with a fixed surface (`device.info`, `device.status`,
`system.notify`, and the `notifications` permission):

1. The iPhone mints `device.pair.setupCode` with `bootstrapProfile: "voice-node"` and
   sends `watch.node.setup` to the watch over WatchConnectivity.
2. The watch calls `install(_:)` with the setup, then `start()` when the scene becomes
   active and `stop()` in the background.
3. The client pairs with the bootstrap token, stores the device token in
   ``DeviceAuthStore`` (scoped to `watch-direct:https://host:port<path>`), and reconnects
   with it after the gateway invalidates the session.

The setup must advertise a system-trusted `wss://` endpoint; the watch polls the
matching `https://` origin. Plain HTTP, self-signed certificates and fingerprint pins
are not supported, and redirects are refused. On watchOS,
`OpenClawWatchNodeClient.watchDefault(store:profile:notifier:)` wires the
`WKInterfaceDevice` and UserNotifications command router.

Standalone Watch Talk (WebRTC over UDP) is exposed as metadata only
(`OpenClawWatchTalkSupport`); `voiceAccess()` returns the bounded voice credential.

## Related Symbols

- ``TalkGatewayClient``
- ``TalkSpeechFallbackChain``
- ``OpenClawWatchNodeClient``
- ``OpenClawWatchMessageCodec``
- ``OpenClawWatchChatDeliveryStore``
