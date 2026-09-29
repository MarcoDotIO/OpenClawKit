# Native State and Device Identity

Store device identity, gateway tokens and exec approvals in the shared OpenClaw state
database.

## Overview

`OpenClawNativeState` (Apple platforms) implements the upstream OpenClaw native state
database, `<stateDir>/state/openclaw.sqlite` (schema v18), on the system SQLite
library. OpenClawKit keeps three things there:

- device identities (`device_identities`), used to sign gateway connects,
- device auth tokens (`device_auth_tokens`), scoped per gateway and identity profile,
- the exec approvals document (`exec_approvals_config`), shared with the Node gateway.

`OpenClawKit` does not re-export `OpenClawNativeState`; import it only if you use the
low-level SQLite API. ``DeviceIdentityStore``, ``DeviceAuthStore`` and
``ExecApprovalsSQLiteStore`` are in OpenClawKit.

## Loading the device identity

```swift
import OpenClawKit

// Throwing and never silently rotating a stored identity.
let identity = try DeviceIdentityStore.loadOrCreatePersistedOrThrow(profile: .primary)

// From an actor or other async code, keep blocking SQLite work off the concurrency pool.
let nodeIdentity = try await DeviceIdentityStore.loadOrCreatePersistedInBackground(profile: .node)
```

Identity profiles (`GatewayDeviceIdentityProfile`) separate the app (`.primary`), a
node session (`.node`) and a share extension (`.shareExtension`). Every native-state API
is synchronous and blocking; the `…InBackground` variants and
`OpenClawNativeStateQueue.run(_:)` run it on one dedicated serial queue.

The deprecated `loadOrCreate()` no longer crashes on storage failure. It logs, records
`lastPersistenceFailureDescription()` and returns an ephemeral identity that a gateway
sees as a new, unpaired device, so migrate to the throwing API.

## Upgrading from JSON files

SDKs before 2026.3.0 stored `identity/device.json` and `identity/device-auth.json`.
On first use the SDK:

1. claims `device.json` by renaming it to `.native-importing`;
2. validates it strictly (a regular file with one link, at most 64 KiB, no symlink
   traversal);
3. commits it to SQLite with the same `deviceId`, then deletes the file.

`device-auth.json` is imported on the first ``DeviceAuthStore`` call. Undecodable auth
files are renamed to `*.invalid-<epochMs>`. A pending `.doctor-importing` claim from the
OpenClaw CLI blocks startup with "run openclaw doctor --fix". Users keep their pairing;
downgrading to an older SDK afterwards creates a new identity and needs re-pairing.

## Gateway-scoped tokens

Device tokens are stored per gateway (`deviceAuthGatewayID`) and per identity profile:

```swift
var options = GatewayConnectOptions.defaultOperator(displayName: "My App")
options.deviceAuthGatewayID = "gw-prod"           // tokens issued by this gateway stay with it
```

The gateway channel follows upstream reuse rules: a scanned setup code forces the
bootstrap path, bootstrap handoffs persist only bounded scopes over TLS, loopback or a
cleartext LAN, device-token retry happens only on trusted endpoints, and a stale token
is cleared on `AUTH_DEVICE_TOKEN_MISMATCH`. `DeviceAuthStore.migrateUnscopedToken` and
`discardUnscopedTokens` handle tokens written before gateway scoping.

## Choosing the state directory

The state directory is resolved in this order:

1. a test scope,
2. ``DeviceIdentityStore/configureStateDirectory(_:)``,
3. `OPENCLAW_STATE_DIR`,
4. the App Group named by the Info.plist key `OpenClawAppGroupIdentifier` (`<container>/OpenClaw`;
   on macOS only when the app is entitled for the group),
5. `~/Library/Application Support/OpenClaw` (unchanged default),
6. `$TMPDIR/openclaw`.

Share extensions and widgets share identity only through the App Group key; there is no
default group. Add `OpenClawAppGroupIdentifier` to the app and every extension.

### Sharing with the OpenClaw CLI (macOS)

Unsandboxed macOS apps can opt in to the CLI's state directory (`OPENCLAW_STATE_DIR` or
`~/.openclaw[-profile]`) so the app, the CLI and a local gateway use one identity and one
exec-approvals document:

```swift
#if os(macOS)
let shared = OpenClawStateDirectory.cliShared()
_ = DeviceIdentityStore.configureStateDirectory(shared)   // before first use
let approvals = try ExecApprovalsSQLiteStore.read(stateDirectoryURL: shared)
#endif
```

Sandboxed apps cannot reach this directory.

## Exec approvals

``ExecApprovalsSQLiteStore`` reads and writes the `exec_approvals_config` row that the
Node gateway also uses. Nodes serve `system.execApprovals.get/set` with
`OpenClawSystemExecApprovalsHandler(stateDirectoryURL:)`, carry
`OpenClawSystemRunApprovalPolicySnapshot` on `system.run`, and on macOS bind the
approved executable with `OpenClawSystemRunLaunchGuard` so it is re-checked (real path
and SHA-256) right before launch. `SecurityRuntime` allowlists can persist in the same
document through `ExecApprovalsSQLiteAllowlistStore`.

The SDK never imports a legacy `exec-approvals.json`: that migration belongs to
`openclaw doctor --fix`, and access fails with `ExecApprovalsLegacyMigrationRequiredError`
while it is pending.

## Schema and safety

- Native code never migrates the schema. A database with `user_version` above 18 fails
  closed with "uses newer schema version"; link `OpenClawNativeStateSQLite.schemaDocsURL`
  in error UI. `schemaStatus()` reports the current state.
- Opens fail fast with "Could not acquire state-handles coordinator" while the CLI backs
  up or restores the database; retry later.
- Files are private (`0700` directory, `0600` files) with data protection; macOS
  connections use `fullfsync`. The journal mode is left to the schema owner.
- `Scripts/check-native-state-parity.mjs` verifies the schema version and canonical DDL
  against the pinned upstream checkout.

## Privacy

The identity's private key never leaves the device and is only used to sign connect
proofs. StateReporting and diagnostics never include device tokens; session keys are
reported as a 16-hex SHA-256 prefix.

## Related Symbols

- ``DeviceIdentityStore``
- ``DeviceAuthStore``
- ``GatewayDeviceIdentityProfile``
- ``OpenClawStateDirectory``
- ``ExecApprovalsSQLiteStore``
