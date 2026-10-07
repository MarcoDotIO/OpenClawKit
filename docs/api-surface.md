# OpenClawSDK API Surface

`OpenClawSDK` provides high-level app entry points that compose lower-level modules.

For end-to-end integration guides and symbol documentation, prefer the published
Swift-DocC site. This file is the quick in-repo index for the highest-level SDK
entry points and the main types behind them.

## Configuration and Session Storage

- `loadConfig(from:cacheTTLms:)`
- `saveConfig(_:to:)`
- `loadConfigRuntime(fromOpenClawJSON:base:environment:stateReporter:)` — reads an
  upstream `openclaw.json` (JSON5, doctor migrations, `${VAR}` substitution) and
  returns the runtime `OpenClawConfig`, group-chat options, per-channel messaging
  policy and config health (`OpenClawConfigRuntime`)
- `loadGatewayConfigDocument(...)` and `importConfig(...)` — the lossless
  `OpenClawConfigDocument` layer and its bridge to `OpenClawConfig`
- `loadSessionStore(from:)`
- `saveSessionStore(_:)`
- `resolveSessionKey(explicit:context:config:)`

## Runtime and Execution

- `makeEmbeddedAgentStack(stateDirectory:credentialStore:modelRouter:agentID:workspaceRoot:loopConfiguration:toolsConfiguration:)`
  — persistent `EmbeddedAgentRuntime` (tool-calling loop, `ask_user`, sub-agents,
  goals, task ledger, progress cards) plus an in-process `GatewayServer` with every
  runtime method registered
- `makeGatewayServer(sessionStore:credentialStore:modelRouter:runtime:workspaceRoot:secretIndexURL:browserRequestHandler:)`
- `runExec(_:cwd:)`
- `runCommandWithTimeout(_:timeoutMs:cwd:)`
- `waitForever()`

## Environment and System

- `ensurePortAvailable(_:)`
- `ensureBinary(_:)`

## Channel and Reply Flows

- `monitorWebChannel(config:sessionStoreURL:diagnosticsPipeline:)`
- `getReplyFromConfig(config:sessionStoreURL:inbound:diagnosticsPipeline:)`
- `channelsStatus(via:probe:channelFilter:)`, `channelPairingList(via:channelFilter:accountID:)`,
  `approveChannelPairing(via:channelID:accountID:requestID:notify:)` and
  `dismissChannelPairing(via:channelID:accountID:requestID:)` — typed wrappers
  over the `channels.*` gateway methods

## Observability Helpers

- `makeDiagnosticsPipeline(eventLimit:)`
- `runSecurityAudit(options:diagnosticsPipeline:)`
- `OpenClawSystemState.isEnabled` and `OpenClawSystemState.diagnosticSink(reporter:forwardingTo:)`
  — opt-in Apple StateReporting (OS 27) for gateway, node invoke, agent run, talk
  and config state

## Gateway (in-process server)

- `GatewayServer` table-driven dispatch over `GatewayMethodCatalog` (482 upstream
  core methods): `register(method:descriptor:handler:)`, typed
  `register(method:params:handler:)`, `unregister(method:)`,
  `addMethodResolver(_:)`, `supportedMethods()`, `advertisedMethods()`
- `GatewayMethodRequest`, `GatewayConnectionContext`, `GatewayEventEmitter`,
  `GatewayMethodError`
- `events(filter:bufferingNewest:)`, `broadcast(event:payload:)`,
  `beginStartup(gating:)` / `completeStartup()` / `runStartup(gating:_:)`
- Module registration functions: `registerChannelGatewayMethods(on:context:)`,
  `registerSkillsGatewayMethods(on:configuration:)`,
  `registerClawHubGatewayMethods(on:client:)`,
  `registerMemoryGatewayMethods(on:configuration:)`,
  `registerCronGatewayMethods(on:scheduler:)`,
  `registerPluginGatewayMethods(on:registry:)`,
  `registerMCPOAuthGatewayMethods(on:clients:)` and
  `EmbeddedAgentRuntime.attach(to:options:)`

## Gateway (client and node)

- `GatewayChannelActor` (operator/node WebSocket client): `request(method:params:timeoutMs:)`,
  `negotiatedProtocolVersion()`, `currentHelloPolicy()`, `reconnectIfStale(now:)`,
  `nudgeReconnect()`, `pendingTLSPinRotationRequest()`, `acceptTLSPinRotation(_:)`
- `GatewayConnectOptions` (`defaultOperator(displayName:)`,
  `defaultNode(caps:commands:permissions:)`, `minimumProtocolVersion`,
  `deviceAuthGatewayID`, `deviceProofPayload`, `handshakeTimeoutMs`)
- `GatewayNodeSession` (route leases, invoke registry, plugin surfaces),
  `GatewayOperatorClient`, `GatewaySessionsClient`, `TalkGatewayClient`,
  `ChannelsGatewayClient`
- `GatewayConnectionProblem` / `GatewayConnectionProblemMapper` for user-facing
  connection errors
- `DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile:)` and
  `DeviceAuthStore` (backed by `OpenClawNativeState`)

## Apple System Integration

- `OpenClawAppIntents.configure(host:)` with `EmbeddedOpenClawIntentHost` or
  `GatewayOpenClawIntentHost`; `OpenClawAppIntentsPackage`
- `OpenClawNowPlaying.makeSystemPublisher()` / `makeExtensionSafePublisher()`
- `OpenClawBackgroundTasks.submit(_:)` and `submitContinuedProcessing(_:)`
- `OpenClawRunProgress`, `OpenClawApprovalGate`, `OpenClawPermissionsSnapshot`,
  `OpenClawLocalNetworkAccessGate`, `OpenClawAgentRunActivityReducer`

## OpenAI Decisions

- `OpenAIDecisionsClient.create(_:)` (`OpenClawModels`, Apple platforms and Linux):
  official `POST /v1/decisions` with an explicit key or `OPENAI_API_KEY` from the
  host environment, injectable HTTP transport and account-scoping options
- `OpenAIDecisionRequest`, `OpenAIDecisionInput`, `OpenAIDecisionQuestion`: shared
  text/inline-image evidence and typed predicate, choice and score questions
- `OpenAIDecisionResponse`, `OpenAIDecisionAnswer`, `OpenAIDecisionUsage`: ordered
  typed answers, refusals, probabilities, confidence and token usage
- `OpenAIDecisionsHTTPError`: redacted HTTP failure details and retry metadata
- DocC article "OpenAI Decisions" for configuration and examples

## Security and Hardening Types

- `SecurityAuditOptions`
- `SecurityAuditReport`
- `SecurityAuditFinding`
- `SecurityAuditSeverity`
- `CredentialStore` (core protocol for secure secret persistence)
- `GatewayTransportSecurityPolicy`, `LocalNetworkHostPolicy`
- `GatewayTLSPinningSession`, `GatewayTLSPinRotationRequest`
- `SecretPathSecurity`, `ExecAllowlistMatcher`, `SecurityRuntime`

## Related Supporting Types

- `OpenClawConfig`, `OpenClawConfigDocument`, `OpenClawConfigDocumentStore`
- `SessionStore`, `SessionTranscriptStore`, `JSONLSessionTranscriptStore`
- `InboundMessage`, `OutboundMessage`, `AutoReplyEngine`, `ChannelPairingStore`
- `ModelRouter`, `ModelProvider`, `ModelGenerationRequest`, `ModelGenerationResponse`
- `FoundationModelsProvider`, `OpenClawReferenceProviderCatalog`
- `AgentTool`, `AgentToolDescriptor`, `AgentToolRegistry`
- `RuntimeDiagnosticsPipeline`, `RuntimeDiagnosticEvent`, `RuntimeUsageSnapshot`
- `PortInUseError`, `ProcessResult`
- `OpenClawChatViewModel`, `OpenClawChatTransport`, `OpenClawGatewaySessionChatTransport`
  (OpenClawChatUI), `OpenClawClientDatabases` (OpenClawChatStore)
