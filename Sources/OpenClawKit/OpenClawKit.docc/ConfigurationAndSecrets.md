# Configuration and Secrets

`OpenClawKit` keeps SDK configuration in ``OpenClawConfig`` and treats secret
material as a first-class concern through ``SecretInput``, ``SecretRef``, and
``CredentialStore``. An upstream-shaped `openclaw.json` can be read losslessly with
`OpenClawConfigDocument`.

## Two Config Layers

- ``OpenClawConfig`` is the SDK-native runtime configuration. Decoding is lenient: an
  unknown enum value becomes `nil` or its default and is recorded as a
  `ConfigDecodeIssue` instead of failing the whole config.
- `OpenClawConfigDocument` is a lossless model of upstream `openclaw.json` (`2026.9.6`).
  Unknown keys and mistyped values are preserved and decode issues are reported.
  `OpenClawJSON5` reads and writes JSON5 with authored key order, and
  `OpenClawConfigMigrator` applies the deterministic upstream doctor migrations by rule id.

Bridge between them with `OpenClawConfig.importConfig(from:issues:)` and
`documentProjection(preserving:)`. The simplest way to consume an upstream file is
``OpenClawSDK/loadConfigRuntime(fromOpenClawJSON:base:environment:stateReporter:)``:

```swift
let runtime = try await OpenClawSDK.shared.loadConfigRuntime(fromOpenClawJSON: configURL)
let config = runtime.config                          // OpenClawConfig for the SDK runtime
let discordPolicy = runtime.messagingPolicy(for: "discord")
for issue in runtime.issues { print(issue) }
```

It resolves `${VAR}` templates for the runtime (never write `runtimeDocument` back),
reports config health through StateReporting when enabled, and returns group-chat
options for `AutoReplyEngine(groupChat:)`.

To collect issues from SDK-native JSON:

```swift
let (config, issues) = try ConfigDecodeIssueCollector.decode(OpenClawConfig.self, from: data)
```

## Plaintext or Secret References

Secret-bearing fields accept a plaintext value, an environment placeholder, or a
structured secret reference. `"${OPENAI_API_KEY}"` and the `$OPENAI_API_KEY` shorthand
decode into an env ``SecretRef``; `file`, `exec` and `store` sources are also supported.

```json
{
  "secrets": {
    "providers": {
      "default": {
        "source": "env",
        "allowlist": ["OPENAI_API_KEY"]
      }
    }
  },
  "models": {
    "providers": {
      "openai": {
        "enabled": true,
        "auth": "api-key",
        "apiKey": "${OPENAI_API_KEY}",
        "baseUrl": "https://api.openai.com/v1"
      }
    }
  }
}
```

- Provider configs use the upstream key `baseUrl` (the legacy `baseURL` still decodes
  and is recorded as an issue). A missing `baseUrl` is filled from the catalog for
  bundled providers. An unknown `api` is kept for round-tripping and the provider is
  skipped.
- `apiKey` and provider `headers` accept SecretInput, so
  `"headers": { "anthropic-workspace-id": "${ANTHROPIC_WORKSPACE_ID}" }` works.
- File SecretRefs must be regular, single-link files owned by the current user with no
  group or world access (`chmod 600`). Exec SecretRef commands must be absolute,
  non-symlink, owned by the current user, not group/world-writable and inside
  `trustedDirs` when set.
- Placeholder shared secrets (`changeme`, redaction sentinels, template stubs) fail
  gateway auth validation.

## Persistence

Use ``OpenClawSDK/loadConfig(from:cacheTTLms:)`` and
``OpenClawSDK/saveConfig(_:to:)`` for file-backed SDK JSON configuration. `ConfigStore.save`
merges onto the file on disk (unknown top-level keys, `gateway.auth`, `gateway.mode`,
`meta` and `wizard` are kept). Back auth material with a concrete ``CredentialStore``
such as ``KeychainCredentialStore`` or ``FileCredentialStore``.

For upstream files, `OpenClawConfigDocumentStore` applies the upstream write guards:
base-hash conflicts, `$include` refusal, a future-version block
(`OPENCLAW_ALLOW_OLDER_BINARY_DESTRUCTIVE_ACTIONS` overrides it), a `gateway.auth`
removal guard (`SaveOptions.allowGatewayAuthRemoval`), SDK-only key stripping, a
5-slot backup ring and atomic `0600` writes. Paths follow `OPENCLAW_CONFIG_PATH`,
`OPENCLAW_STATE_DIR`, `OPENCLAW_PROFILE` and `OPENCLAW_HOME`. SDK state directories are
created `0700` and state files written `0600`.

For a remote gateway, fetch with `fetchConfigSnapshot`, build a merge patch with
`ConfigMergePatchBuilder`, and call `patchConfig` with the returned `baseHash` and
`replacePaths`.

## Managed Configuration

On iOS 18.4+, visionOS 2.4+ and macOS 27+, `ManagedConfigurationOverlay` applies a
ManagedApp.framework MDM payload (a `gateway.remote` subset, `ui`, `lockedPaths`, and
`secretIdentifiers` that map config paths to managed passwords). Managed values are
runtime-only and never written to `openclaw.json`. `ManagedGatewayClientIdentity`
provides a managed mTLS identity for gateway connections.

## Related Symbols

- ``OpenClawConfig``
- ``SecretInput``
- ``SecretRef``
- ``SecretsConfig``
- ``CredentialStore``
