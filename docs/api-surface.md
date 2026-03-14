# OpenClawSDK API Surface

`OpenClawSDK` provides high-level app entry points that compose lower-level modules.

For end-to-end integration guides and symbol documentation, prefer the published
Swift-DocC site. This file is the quick in-repo index for the highest-level SDK
entry points.

## Configuration and Session Storage

- `loadConfig(from:cacheTTLms:)`
- `saveConfig(_:to:)`
- `loadSessionStore(from:)`
- `saveSessionStore(_:)`
- `resolveSessionKey(explicit:context:config:)`

## Runtime and Execution

- `runExec(_:cwd:)`
- `runCommandWithTimeout(_:timeoutMs:cwd:)`
- `waitForever()`

## Environment and System

- `ensurePortAvailable(_:)`
- `ensureBinary(_:)`

## Channel and Reply Flows

- `monitorWebChannel(config:sessionStoreURL:diagnosticsPipeline:)`
- `getReplyFromConfig(config:sessionStoreURL:inbound:diagnosticsPipeline:)`

## Observability Helpers

- `makeDiagnosticsPipeline(eventLimit:)`
- `runSecurityAudit(options:diagnosticsPipeline:)`

## Security and Hardening Types

- `SecurityAuditOptions`
- `SecurityAuditReport`
- `SecurityAuditFinding`
- `SecurityAuditSeverity`
- `CredentialStore` (core protocol for secure secret persistence)

## Related Supporting Types

- `OpenClawConfig`
- `SessionStore`
- `InboundMessage`
- `OutboundMessage`
- `RuntimeDiagnosticsPipeline`
- `RuntimeDiagnosticEvent`
- `RuntimeUsageSnapshot`
- `SecurityAuditReport`
- `PortInUseError`
- `ProcessResult`
- `OpenClawChatViewModel`
- `OpenClawChatTransport`
