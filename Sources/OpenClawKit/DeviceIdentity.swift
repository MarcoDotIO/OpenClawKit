import CryptoKit
import Foundation
import OpenClawNativeState
import OSLog
#if canImport(Security)
import Security
#endif

/// Device identity slots. Separate app surfaces (the main app, a node host, a share extension)
/// keep separate Ed25519 identities and therefore separate gateway pairings.
///
/// The raw value is the `identity_key` column of the shared `device_identities` table, so the
/// `primary` identity is the one the OpenClaw CLI/gateway reads when they share a state directory.
public enum GatewayDeviceIdentityProfile: String, Sendable {
    /// The app's main identity (`identity_key = "primary"`).
    case primary
    /// Identity used when the app acts as a node host (`identity_key = "node"`).
    case node
    /// Identity used by a share extension (`identity_key = "shareExtension"`).
    case shareExtension

    var identityFileName: String {
        switch self {
        case .primary:
            "device.json"
        case .node:
            "node-device.json"
        case .shareExtension:
            "share-device.json"
        }
    }

    var authFileName: String {
        switch self {
        case .primary:
            "device-auth.json"
        case .node:
            "node-device-auth.json"
        case .shareExtension:
            "share-device-auth.json"
        }
    }
}

/// Device identity payload used for gateway signing and device-auth handshakes.
///
/// `publicKey` and `privateKey` are base64 of the raw 32-byte Ed25519 keys; `deviceId` is the
/// lowercase hex SHA-256 of the raw public key.
public struct DeviceIdentity: Codable, Sendable, Equatable {
    /// Stable device identifier derived from the public key.
    public var deviceId: String
    /// Base64-encoded raw Ed25519 public key.
    public var publicKey: String
    /// Base64-encoded raw Ed25519 private key.
    public var privateKey: String
    /// Creation timestamp in milliseconds since the Unix epoch (`Int64`, safe on arm64_32 watchOS).
    public var createdAtMs: Int64

    /// Creates a device identity payload.
    public init(deviceId: String, publicKey: String, privateKey: String, createdAtMs: Int64) {
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.createdAtMs = createdAtMs
    }
}

struct DeviceIdentityStateRootState {
    private(set) var url: URL?
    private(set) var used = false

    mutating func configure(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        if let configured = self.url { return configured == normalized }
        guard !self.used else { return false }
        self.url = normalized
        return true
    }

    mutating func resolve() -> URL? {
        self.used = true
        return self.url
    }
}

enum DeviceIdentityPaths {
    private static let stateDirEnv = ["OPENCLAW_STATE_DIR"]
    /// Info.plist key naming the App Group whose container holds shared OpenClaw state.
    static let appGroupIdentifierInfoKey = "OpenClawAppGroupIdentifier"
    @TaskLocal static var scopedStateDirURL: URL?
    private static let configuredStateLock = NSLock()
    private nonisolated(unsafe) static var configuredState = DeviceIdentityStateRootState()

    /// App Group used for shared state, read from the host's Info.plist.
    ///
    /// SDK adaptation: upstream falls back to its own `group.ai.openclawfoundation.app.shared`, which
    /// belongs to the official app's team. SDK hosts opt in by setting `OpenClawAppGroupIdentifier`.
    static let appGroupIdentifier: String? = {
        let raw = Bundle.main.object(forInfoDictionaryKey: DeviceIdentityPaths.appGroupIdentifierInfoKey) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }()

    /// Entitlements are baked into the code signature, so resolve the gate once per process.
    /// Every identity load and DeviceAuthStore read/write resolves the state dir through here;
    /// re-creating a SecTask each time is wasted work for a process-immutable fact.
    private static let appGroupStateDirAvailable: Bool = {
        guard let identifier = DeviceIdentityPaths.appGroupIdentifier else { return false }
        return DeviceIdentityPaths.hasAppGroupEntitlement(identifier)
    }()

    static func stateDirURL() -> URL {
        self.stateDirURL(
            overrideURL: self.stateDirOverrideURL(),
            legacyStateDirURL: self.legacyStateDirURL(),
            appGroupStateDirURL: self.appGroupStateDirAvailable ? self.appGroupStateDirURL() : nil,
            appGroupStateDirAvailable: self.appGroupStateDirAvailable,
            temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    static func configureStateDirURL(_ url: URL) -> Bool {
        self.configuredStateLock.withLock { self.configuredState.configure(url) }
    }

    static func stateDirURL(
        overrideURL: URL?,
        legacyStateDirURL: URL?,
        appGroupStateDirURL: URL?,
        appGroupStateDirAvailable: Bool = true,
        temporaryDirectory: URL) -> URL
    {
        if let overrideURL {
            return overrideURL
        }
        if appGroupStateDirAvailable, let appGroupStateDirURL {
            return appGroupStateDirURL
        }
        if let legacyStateDirURL {
            return legacyStateDirURL
        }
        return temporaryDirectory.appendingPathComponent("openclaw", isDirectory: true)
    }

    private static func stateDirOverrideURL() -> URL? {
        // Test-scoped stores must win over the process environment. Parallel Swift tests
        // otherwise race whenever another suite temporarily swaps OPENCLAW_STATE_DIR.
        if let scopedStateDirURL {
            return scopedStateDirURL
        }
        if let configured = self.configuredStateLock.withLock({ self.configuredState.resolve() }) {
            return configured
        }
        for key in self.stateDirEnv {
            if let raw = getenv(key) {
                let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return URL(fileURLWithPath: value, isDirectory: true)
                }
            }
        }
        return nil
    }

    static func legacyStateDirURL() -> URL? {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("OpenClaw", isDirectory: true)
        }
        return nil
    }

    private static func hasAppGroupEntitlement(_ identifier: String) -> Bool {
        // macOS resolves containerURL(forSecurityApplicationGroupIdentifier:) even without the
        // App Groups entitlement, but macOS 15+ gates actual access behind a user consent prompt.
        // Unentitled builds must not depend on that container. iOS requires the entitlement for
        // containerURL to resolve at all, so the gate is macOS-only.
        #if os(macOS) && canImport(Security)
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil)
        else {
            return false
        }
        guard let groups = value as? [String] else {
            return false
        }
        return groups.contains(identifier)
        #else
        return true
        #endif
    }

    static func appGroupStateDirURL() -> URL? {
        guard
            let identifier = self.appGroupIdentifier,
            let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else {
            return nil
        }
        return containerURL.appendingPathComponent("OpenClaw", isDirectory: true)
    }

    struct LegacyIdentitySource: Equatable {
        let stateDirURL: URL
        let identityURL: URL
        let authURL: URL
    }

    static func legacyIdentitySources(
        profile: GatewayDeviceIdentityProfile) -> [LegacyIdentitySource]
    {
        // Node doctor cannot traverse sandboxed Apple App Group/Application Support containers.
        // Native startup therefore owns this one-time import before runtime becomes SQLite-only.
        let selectedStateDirURL = self.stateDirURL()
        let roots: [URL] = if self.scopedStateDirURL != nil || self.stateDirOverrideURL() != nil {
            // Explicit and task-local stores must never import the machine's real identity.
            [selectedStateDirURL]
        } else {
            // Hosts that adopt an App Group keep their former Application Support identity and
            // auth together instead of rotating/re-pairing. SDK adaptation: the App Group root is
            // probed only when the host is entitled for it (upstream probes its own former group).
            [
                selectedStateDirURL,
                self.appGroupStateDirAvailable ? self.appGroupStateDirURL() : nil,
                self.legacyStateDirURL(),
            ].compactMap(\.self)
        }

        var seen = Set<String>()
        return roots.compactMap { root in
            let standardizedRoot = root.standardizedFileURL
            guard seen.insert(standardizedRoot.path).inserted else { return nil }
            let identityDirURL = standardizedRoot.appendingPathComponent("identity", isDirectory: true)
            return LegacyIdentitySource(
                stateDirURL: standardizedRoot,
                identityURL: identityDirURL.appendingPathComponent(profile.identityFileName, isDirectory: false),
                authURL: identityDirURL.appendingPathComponent(profile.authFileName, isDirectory: false))
        }
    }

    static func databaseURL(stateDirURL: URL) -> URL {
        stateDirURL
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("openclaw.sqlite", isDirectory: false)
    }

    /// Runs blocking native-state work on the dedicated native-state queue, carrying the caller's
    /// task-scoped state directory across the hop (task-local values do not follow GCD work).
    static func runOnNativeStateQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let scoped = self.scopedStateDirURL
        return try await OpenClawNativeStateQueue.run {
            try DeviceIdentityPaths.$scopedStateDirURL.withValue(scoped) {
                try work()
            }
        }
    }
}

struct DeviceIdentityMaterial: Equatable {
    let identity: DeviceIdentity
    let publicKeyPEM: String
    let privateKeyPEM: String
}

/// Loads, creates, and signs with the persisted device identity.
///
/// Identities live in the shared native state database `<stateDir>/state/openclaw.sqlite`
/// (`device_identities`, keyed by ``GatewayDeviceIdentityProfile``). The state directory resolves,
/// first match wins, to: a test-scoped directory, ``configureStateDirectory(_:)``,
/// `OPENCLAW_STATE_DIR`, the App Group container named by the Info.plist key
/// `OpenClawAppGroupIdentifier` (`<container>/OpenClaw`), `~/Library/Application Support/OpenClaw`,
/// then `$TMPDIR/openclaw`.
///
/// Upgrading from the JSON store: on first use, `<stateDir>/identity/device.json` (and the
/// profile-specific `node-device.json`/`share-device.json`) is claimed and imported with the same
/// `deviceId`, so existing gateway pairings keep working; the matching `device-auth.json` tokens are
/// imported by ``DeviceAuthStore``. The JSON files are removed after the SQLite row commits.
///
/// All methods are synchronous and may block on SQLite locks; from async code prefer
/// ``loadOrCreatePersistedInBackground(profile:)``.
public enum DeviceIdentityStore {
    static let ed25519SPKIPrefix = Data([
        0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65,
        0x70, 0x03, 0x21, 0x00,
    ])
    static let ed25519PKCS8PrivatePrefix = Data([
        0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
        0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
    ])

    private static let logger = Logger(subsystem: "ai.openclaw.kit", category: "device-identity")
    private static let fallbackLock = NSLock()
    private nonisolated(unsafe) static var ephemeralFallbacks: [String: DeviceIdentity] = [:]
    private nonisolated(unsafe) static var lastFailureDescription: String?

    static func storageError(_ message: String) -> NSError {
        NSError(
            domain: "ai.openclaw.device-identity-store",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Loads or creates the primary identity without surfacing storage failures.
    ///
    /// Upstream crashes when the identity cannot be persisted. The SDK instead logs the failure,
    /// records it for ``lastPersistenceFailureDescription()``, and returns a process-lifetime
    /// ephemeral identity (which a gateway will treat as a new, unpaired device).
    @available(*, deprecated, message: "Use loadOrCreatePersistedOrThrow(profile:) so storage failures surface.")
    public static func loadOrCreate() -> DeviceIdentity {
        self.loadOrCreateOrEphemeral(profile: .primary)
    }

    /// Sets the process-wide state directory before first use.
    ///
    /// - Returns: `false` when a different directory is already configured, or when the state
    ///   directory has already been resolved by an earlier identity or device-auth call.
    @discardableResult
    public static func configureStateDirectory(_ url: URL) -> Bool {
        DeviceIdentityPaths.configureStateDirURL(url)
    }

    #if compiler(>=6.4)
    nonisolated(nonsending) static func withStateDirectory<T>(
        _ url: URL,
        operation: () async throws -> T) async rethrows -> T
    {
        try await DeviceIdentityPaths.$scopedStateDirURL.withValue(url) {
            try await operation()
        }
    }
    #else
    static func withStateDirectory<T>(
        _ url: URL,
        operation: () async throws -> T,
        isolation: isolated (any Actor)? = #isolation) async rethrows -> T
    {
        try await DeviceIdentityPaths.$scopedStateDirURL.withValue(
            url,
            operation: operation,
            isolation: isolation)
    }
    #endif

    /// Loads or creates the identity for `profile` without surfacing storage failures.
    ///
    /// On failure this logs, records the failure for ``lastPersistenceFailureDescription()``, and
    /// returns an ephemeral identity cached for the rest of the process (never persisted).
    @available(*, deprecated, message: "Use loadOrCreatePersistedOrThrow(profile:) so storage failures surface.")
    public static func loadOrCreate(profile: GatewayDeviceIdentityProfile) -> DeviceIdentity {
        self.loadOrCreateOrEphemeral(profile: profile)
    }

    /// Non-deprecated body of ``loadOrCreate(profile:)``: persisted identity, or a cached ephemeral one.
    static func loadOrCreateOrEphemeral(profile: GatewayDeviceIdentityProfile) -> DeviceIdentity {
        do {
            return try self.loadOrCreatePersistedOrThrow(profile: profile)
        } catch {
            return self.ephemeralFallback(profile: profile, error: error)
        }
    }

    /// Loads or creates an identity, returning nil unless its key material was durably persisted.
    public static func loadOrCreatePersisted(
        profile: GatewayDeviceIdentityProfile = .primary) -> DeviceIdentity?
    {
        try? self.loadOrCreatePersistedOrThrow(profile: profile)
    }

    /// Loads or creates an identity and preserves the storage failure for callers that can report it.
    ///
    /// Never rotates a stored identity silently: a corrupt row, a pending `openclaw doctor --fix`
    /// import, conflicting legacy files, or an unsupported schema version throws instead.
    public static func loadOrCreatePersistedOrThrow(
        profile: GatewayDeviceIdentityProfile = .primary) throws -> DeviceIdentity
    {
        let stateDirURL = DeviceIdentityPaths.stateDirURL()
        do {
            return try DeviceIdentitySQLiteStore.loadOrCreate(
                databaseURL: DeviceIdentityPaths.databaseURL(stateDirURL: stateDirURL),
                destinationStateDirURL: stateDirURL,
                profile: profile,
                legacySources: DeviceIdentityPaths.legacyIdentitySources(profile: profile))
        } catch {
            throw NSError(
                domain: "ai.openclaw.device-identity-store",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not access the persisted device identity: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error,
                ])
        }
    }

    /// Describes the most recent storage failure that forced a deprecated ``loadOrCreate(profile:)``
    /// call to return an ephemeral identity, or nil when none occurred in this process.
    public static func lastPersistenceFailureDescription() -> String? {
        self.fallbackLock.withLock { self.lastFailureDescription }
    }

    /// Signs a payload string with the device private key and returns a base64url signature.
    public static func signPayload(_ payload: String, identity: DeviceIdentity) -> String? {
        guard let privateKeyData = Data(base64Encoded: identity.privateKey) else { return nil }
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: Data(payload.utf8))
            return self.base64UrlEncode(signature)
        } catch {
            return nil
        }
    }

    static func generateMaterial() -> DeviceIdentityMaterial {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let publicKeyData = publicKey.rawRepresentation
        let privateKeyData = privateKey.rawRepresentation
        let deviceId = self.deviceId(publicKeyData: publicKeyData)
        let identity = DeviceIdentity(
            deviceId: deviceId,
            publicKey: publicKeyData.base64EncodedString(),
            privateKey: privateKeyData.base64EncodedString(),
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        return DeviceIdentityMaterial(
            identity: identity,
            publicKeyPEM: self.pem(label: "PUBLIC KEY", der: self.ed25519SPKIPrefix + publicKeyData),
            privateKeyPEM: self.pem(label: "PRIVATE KEY", der: self.ed25519PKCS8PrivatePrefix + privateKeyData))
    }

    private static func ephemeralFallback(
        profile: GatewayDeviceIdentityProfile,
        error: any Error) -> DeviceIdentity
    {
        let key = "\(DeviceIdentityPaths.stateDirURL().standardizedFileURL.path)#\(profile.rawValue)"
        let description = error.localizedDescription
        self.logger.error(
            """
            Device identity \(profile.rawValue, privacy: .public) is not persisted; \
            using an ephemeral identity: \(description, privacy: .private)
            """)
        return self.fallbackLock.withLock {
            self.lastFailureDescription = description
            if let cached = self.ephemeralFallbacks[key] {
                return cached
            }
            let identity = self.generateMaterial().identity
            self.ephemeralFallbacks[key] = identity
            return identity
        }
    }

    private static func base64UrlEncode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Returns the device public key encoded as base64url.
    public static func publicKeyBase64Url(_ identity: DeviceIdentity) -> String? {
        guard let data = Data(base64Encoded: identity.publicKey) else { return nil }
        return self.base64UrlEncode(data)
    }

    static func material(fromLegacyData data: Data) throws -> DeviceIdentityMaterial {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceIdentityStore.storageError("Legacy device identity is not a JSON object")
        }
        let keys = Set(object.keys)
        let decoder = JSONDecoder()
        if keys == ["deviceId", "publicKey", "privateKey", "createdAtMs"],
           let decoded = try? decoder.decode(DeviceIdentity.self, from: data),
           decoded.createdAtMs >= 0
        {
            guard let normalized = normalizedRawIdentity(decoded),
                  let publicKeyData = Data(base64Encoded: normalized.publicKey),
                  let privateKeyData = Data(base64Encoded: normalized.privateKey)
            else {
                throw DeviceIdentityStore
                    .storageError("Legacy raw device identity has invalid key material or deviceId")
            }
            return DeviceIdentityMaterial(
                identity: normalized,
                publicKeyPEM: self.pem(label: "PUBLIC KEY", der: self.ed25519SPKIPrefix + publicKeyData),
                privateKeyPEM: self.pem(label: "PRIVATE KEY", der: self.ed25519PKCS8PrivatePrefix + privateKeyData))
        }
        if keys == ["version", "deviceId", "publicKeyPem", "privateKeyPem", "createdAtMs"],
           let decoded = try? decoder.decode(PemDeviceIdentity.self, from: data)
        {
            guard decoded.version == 1, decoded.createdAtMs >= 0,
                  let publicKeyData = rawPublicKey(fromPEM: decoded.publicKeyPem),
                  let privateKeyData = rawPrivateKey(fromPEM: decoded.privateKeyPem),
                  keyPairMatches(publicKeyData: publicKeyData, privateKeyData: privateKeyData)
            else {
                throw DeviceIdentityStore.storageError("Legacy PEM device identity has invalid key material")
            }
            return self.material(
                publicKeyData: publicKeyData,
                privateKeyData: privateKeyData,
                createdAtMs: decoded.createdAtMs)
        }
        throw DeviceIdentityStore.storageError("Legacy device identity has an unsupported shape")
    }

    static func material(
        deviceId: String,
        publicKeyPEM: String,
        privateKeyPEM: String,
        createdAtMs: Int64) throws -> DeviceIdentityMaterial
    {
        guard createdAtMs >= 0,
              let publicKeyData = rawPublicKey(fromPEM: publicKeyPEM),
              let privateKeyData = rawPrivateKey(fromPEM: privateKeyPEM),
              keyPairMatches(publicKeyData: publicKeyData, privateKeyData: privateKeyData)
        else {
            throw DeviceIdentityStore.storageError("SQLite device identity has invalid key material")
        }
        let canonical = self.material(
            publicKeyData: publicKeyData,
            privateKeyData: privateKeyData,
            createdAtMs: createdAtMs)
        guard canonical.identity.deviceId == deviceId else {
            throw DeviceIdentityStore.storageError("SQLite device identity deviceId does not match its public key")
        }
        guard canonical.publicKeyPEM == publicKeyPEM, canonical.privateKeyPEM == privateKeyPEM else {
            throw DeviceIdentityStore.storageError("SQLite device identity PEM is not canonical")
        }
        return canonical
    }

    private static func normalizedRawIdentity(_ rawIdentity: DeviceIdentity) -> DeviceIdentity? {
        let rawKey = rawIdentity.privateKey
        guard !rawIdentity.deviceId.isEmpty,
              let publicKeyData = Data(base64Encoded: rawIdentity.publicKey),
              let privateKeyData = Data(base64Encoded: rawKey)
        else { return nil }

        guard publicKeyData.count == 32, privateKeyData.count == 32,
              self.keyPairMatches(publicKeyData: publicKeyData, privateKeyData: privateKeyData)
        else { return nil }
        return DeviceIdentity(
            deviceId: self.deviceId(publicKeyData: publicKeyData),
            publicKey: rawIdentity.publicKey,
            privateKey: rawKey,
            createdAtMs: rawIdentity.createdAtMs)
    }

    static func rawPublicKey(fromPEM pem: String) -> Data? {
        guard let der = derData(fromPEM: pem, label: "PUBLIC KEY"),
              der.count == self.ed25519SPKIPrefix.count + 32,
              der.prefix(self.ed25519SPKIPrefix.count) == self.ed25519SPKIPrefix
        else { return nil }
        return der.suffix(32)
    }

    static func rawPrivateKey(fromPEM pem: String) -> Data? {
        guard let der = derData(fromPEM: pem, label: "PRIVATE KEY"),
              der.count == self.ed25519PKCS8PrivatePrefix.count + 32,
              der.prefix(self.ed25519PKCS8PrivatePrefix.count) == self.ed25519PKCS8PrivatePrefix
        else { return nil }
        return der.suffix(32)
    }

    static func keyPairMatches(publicKeyData: Data, privateKeyData: Data) -> Bool {
        guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        else {
            return false
        }
        return privateKey.publicKey.rawRepresentation == publicKeyData
    }

    private static func derData(fromPEM pem: String, label: String) -> Data? {
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4,
              lines.first == "-----BEGIN \(label)-----",
              lines[lines.count - 2] == "-----END \(label)-----",
              lines.last?.isEmpty == true
        else { return nil }
        let body = lines.dropFirst().dropLast(2)
        guard !body.isEmpty, body.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else { return nil }
        return Data(base64Encoded: body.joined())
    }

    static func deviceId(publicKeyData: Data) -> String {
        SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
    }

    static func material(
        publicKeyData: Data,
        privateKeyData: Data,
        createdAtMs: Int64) -> DeviceIdentityMaterial
    {
        let identity = DeviceIdentity(
            deviceId: deviceId(publicKeyData: publicKeyData),
            publicKey: publicKeyData.base64EncodedString(),
            privateKey: privateKeyData.base64EncodedString(),
            createdAtMs: createdAtMs)
        return DeviceIdentityMaterial(
            identity: identity,
            publicKeyPEM: self.pem(label: "PUBLIC KEY", der: self.ed25519SPKIPrefix + publicKeyData),
            privateKeyPEM: self.pem(label: "PRIVATE KEY", der: self.ed25519PKCS8PrivatePrefix + privateKeyData))
    }

    private static func pem(label: String, der: Data) -> String {
        let base64 = der.base64EncodedString()
        let fence = String(repeating: "-", count: 5)
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start..<end])
        }
        return "\(fence)BEGIN \(label)\(fence)\n\(lines.joined(separator: "\n"))\n\(fence)END \(label)\(fence)\n"
    }
}

private struct PemDeviceIdentity: Codable {
    var version: Int
    var deviceId: String
    var publicKeyPem: String
    var privateKeyPem: String
    var createdAtMs: Int64
}
