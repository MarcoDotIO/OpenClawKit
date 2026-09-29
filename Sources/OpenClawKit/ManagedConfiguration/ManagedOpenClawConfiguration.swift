import Foundation
#if canImport(ManagedApp) && !os(tvOS) && !os(watchOS)
import ManagedApp
#endif
#if canImport(Security)
import Security
#endif

/// Managed (MDM) configuration for OpenClaw apps: a runtime overlay on `openclaw.json`.
///
/// Organizations deliver this payload through Managed App Configuration (ManagedApp.framework on
/// iOS 18.4+, visionOS 2.4+ and macOS 27+). Managed values win over local values, locked paths are
/// reported so UIs can disable editing, and nothing managed is ever written into `openclaw.json`.
public struct ManagedOpenClawConfigPayload: Codable, Sendable, Equatable {
    /// Managed gateway settings (limited to `mode`, `remote.url`, `remote.transport`,
    /// `remote.tlsFingerprint`, `remote.remotePort` and `remote.edgeAuth` header names).
    public var gateway: OpenClawConfigDocument.Gateway?
    /// Managed display preferences.
    public var ui: OpenClawConfigDocument.UI?
    /// Config paths users must not edit (dotted; a path locks its subtree).
    public var lockedPaths: [String]?
    /// Config path → managed password identifier (resolved through ``ManagedSecretSource``).
    public var secretIdentifiers: [String: String]?

    /// Creates a payload.
    /// - Parameters:
    ///   - gateway: Managed gateway settings.
    ///   - ui: Managed display preferences.
    ///   - lockedPaths: Locked config paths.
    ///   - secretIdentifiers: Secret path → managed identifier map.
    public init(
        gateway: OpenClawConfigDocument.Gateway? = nil,
        ui: OpenClawConfigDocument.UI? = nil,
        lockedPaths: [String]? = nil,
        secretIdentifiers: [String: String]? = nil
    ) {
        self.gateway = gateway
        self.ui = ui
        self.lockedPaths = lockedPaths
        self.secretIdentifiers = secretIdentifiers
    }

    /// Provider alias used for managed secret refs (`{source: "store", provider: "managed", id}`).
    public static let secretProviderAlias = "managed"
}

/// Source of managed payloads (the ManagedApp-backed source or a test double).
public protocol ManagedConfigurationSource: Sendable {
    /// Streams the current payload and every change (`nil` when no configuration is installed).
    /// - Returns: Payload updates.
    func payloads() -> AsyncStream<ManagedOpenClawConfigPayload?>
}

/// Source of managed passwords (the ManagedApp-backed source or a test double).
public protocol ManagedSecretSource: Sendable {
    /// Returns the managed password for `identifier`.
    /// - Parameter identifier: Managed password identifier.
    /// - Returns: The password.
    func password(withIdentifier identifier: String) async throws -> String
}

/// Applies managed configuration on top of a local `openclaw.json` document at runtime.
public actor ManagedConfigurationOverlay {
    private let source: any ManagedConfigurationSource
    /// The most recent payload seen by ``updates()``.
    public private(set) var current: ManagedOpenClawConfigPayload?

    /// Creates an overlay over a payload source.
    /// - Parameter source: Payload source.
    public init(source: any ManagedConfigurationSource) {
        self.source = source
    }

    /// Streams managed payload updates and remembers the latest one in ``current``.
    /// - Returns: Payload updates.
    public func updates() -> AsyncStream<ManagedOpenClawConfigPayload?> {
        let upstream = self.source.payloads()
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                for await payload in upstream {
                    await self?.remember(payload)
                    continuation.yield(payload)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func remember(_ payload: ManagedOpenClawConfigPayload?) {
        self.current = payload
    }

    /// Applies the latest payload (see ``apply(_:to:)``).
    /// - Parameter document: Local document.
    /// - Returns: The effective document and the locked paths.
    public func apply(to document: OpenClawConfigDocument) -> (document: OpenClawConfigDocument, lockedPaths: Set<String>) {
        Self.apply(self.current, to: document)
    }

    /// Applies `payload` on top of `document`: managed values win, managed secrets become
    /// `{source: "store", provider: "managed", id}` refs, and every managed path is locked.
    /// - Parameters:
    ///   - payload: Managed payload (`nil` leaves the document unchanged).
    ///   - document: Local document.
    /// - Returns: The effective (runtime-only) document and the locked paths.
    public static func apply(
        _ payload: ManagedOpenClawConfigPayload?,
        to document: OpenClawConfigDocument
    ) -> (document: OpenClawConfigDocument, lockedPaths: Set<String>) {
        guard let payload else {
            return (document, [])
        }
        var tree = document.jsonObject
        var locked = Set(payload.lockedPaths ?? [])
        if let gateway = payload.gateway {
            for (path, value) in Self.allowedGatewayValues(gateway) {
                Self.set(&tree, path: path, value: value)
                locked.insert(path.joined(separator: "."))
            }
        }
        if let ui = payload.ui {
            tree["ui"] = ConfigTree.deepMerge(tree["ui"], AnyCodable(.object(ui.jsonObject)))
            for key in ui.jsonObject.keys {
                locked.insert("ui.\(key)")
            }
        }
        for (path, identifier) in payload.secretIdentifiers ?? [:] {
            let ref: AnyCodable = AnyCodable(.object([
                "source": AnyCodable(.string(SecretRefSource.store.rawValue)),
                "provider": AnyCodable(.string(ManagedOpenClawConfigPayload.secretProviderAlias)),
                "id": AnyCodable(.string(identifier)),
            ]))
            Self.set(&tree, path: path.split(separator: ".").map(String.init), value: ref)
            locked.insert(path)
        }
        var effective = (try? OpenClawConfigDocument.decode(jsonObject: tree, migrateLegacyKeys: false)) ?? document
        effective.agents?.entryOrder = document.agents?.entryOrder ?? []
        return (effective, locked)
    }

    /// Whether `path` (dotted) is inside a locked path.
    /// - Parameters:
    ///   - path: Config path.
    ///   - lockedPaths: Locked paths.
    /// - Returns: `true` when the path or one of its parents is locked.
    public static func isLocked(_ path: String, lockedPaths: Set<String>) -> Bool {
        lockedPaths.contains { locked in path == locked || path.hasPrefix(locked + ".") || locked.hasPrefix(path + ".") }
    }

    /// Locked paths a `config.patch` payload would touch (callers must refuse such patches).
    /// - Parameters:
    ///   - payload: Built patch.
    ///   - lockedPaths: Locked paths.
    /// - Returns: Touched locked paths, sorted.
    public static func lockedPathViolations(in payload: ConfigMergePatchBuilder.Payload, lockedPaths: Set<String>) -> [String] {
        payload.touchedPaths.filter { self.isLocked($0, lockedPaths: lockedPaths) }.sorted()
    }

    private static func allowedGatewayValues(_ gateway: OpenClawConfigDocument.Gateway) -> [([String], AnyCodable)] {
        var values: [([String], AnyCodable)] = []
        if let mode = gateway.mode {
            values.append((["gateway", "mode"], AnyCodable(.string(mode.rawValue))))
        }
        guard let remote = gateway.remote else { return values }
        if let url = remote.url {
            values.append((["gateway", "remote", "url"], AnyCodable(.string(url))))
        }
        if let transport = remote.transport {
            values.append((["gateway", "remote", "transport"], AnyCodable(.string(transport))))
        }
        if let fingerprint = remote.tlsFingerprint {
            values.append((["gateway", "remote", "tlsFingerprint"], AnyCodable(.string(fingerprint))))
        }
        if let port = remote.remotePort {
            values.append((["gateway", "remote", "remotePort"], AnyCodable(.int(port))))
        }
        for (header, value) in remote.edgeAuth ?? [:] where value.ref?.source == .store {
            // Only managed refs are accepted; plaintext header values never come from MDM payloads.
            values.append((["gateway", "remote", "edgeAuth", header], value.raw))
        }
        return values
    }

    private static func set(_ tree: inout [String: AnyCodable], path: [String], value: AnyCodable) {
        guard let key = path.first else { return }
        if path.count == 1 {
            tree[key] = value
            return
        }
        var child = tree[key]?.dictionaryValue ?? [:]
        self.set(&child, path: Array(path.dropFirst()), value: value)
        tree[key] = AnyCodable(.object(child))
    }
}

/// Resolves managed secret refs (`{source: "store", provider: "managed", id}`) through a
/// ``ManagedSecretSource`` and defers every other ref to a fallback resolver.
public struct ManagedSecretRefResolver: SecretRefResolver {
    /// Managed password source.
    public var source: any ManagedSecretSource
    /// Resolver for non-managed refs.
    public var fallback: (any SecretRefResolver)?

    /// Creates a resolver.
    /// - Parameters:
    ///   - source: Managed password source.
    ///   - fallback: Resolver for other refs.
    public init(source: any ManagedSecretSource, fallback: (any SecretRefResolver)? = DefaultSecretRefResolver()) {
        self.source = source
        self.fallback = fallback
    }

    /// Resolves managed refs through the managed source.
    /// - Parameters:
    ///   - ref: Secret reference.
    ///   - config: Secrets config.
    /// - Returns: The secret value.
    public func resolve(_ ref: SecretRef, config: SecretsConfig) async throws -> String {
        if ref.source == .store, ref.provider == ManagedOpenClawConfigPayload.secretProviderAlias {
            return try await self.source.password(withIdentifier: ref.id)
        }
        guard let fallback else {
            throw OpenClawCoreError.unavailable("No resolver is configured for \(ref.source.rawValue) secret refs.")
        }
        return try await fallback.resolve(ref, config: config)
    }
}

#if canImport(ManagedApp) && !os(tvOS) && !os(watchOS)
/// ``ManagedConfigurationSource`` backed by `ManagedAppConfigurationProvider`.
@available(iOS 18.4, visionOS 2.4, macOS 27.0, *)
public struct ManagedAppConfigurationSource: ManagedConfigurationSource {
    /// Creates the system source.
    public init() {}

    /// Streams payloads decoded from the managed app configuration.
    /// - Returns: Payload updates.
    public func payloads() -> AsyncStream<ManagedOpenClawConfigPayload?> {
        AsyncStream { continuation in
            let task = Task {
                let provider = ManagedAppConfigurationProvider()
                for await payload in await provider.configurations(ManagedOpenClawConfigPayload.self) {
                    continuation.yield(payload)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ``ManagedSecretSource`` backed by `ManagedAppPasswordsProvider`.
@available(iOS 18.4, visionOS 2.4, macOS 27.0, *)
public struct ManagedAppPasswordSource: ManagedSecretSource {
    /// Creates the system source.
    public init() {}

    /// Returns a managed password.
    /// - Parameter identifier: Managed password identifier.
    /// - Returns: The password.
    /// - Throws: ``OpenClawCoreError`` mapped from `ManagedAppError`.
    public func password(withIdentifier identifier: String) async throws -> String {
        let provider = ManagedAppPasswordsProvider()
        do {
            return try await provider.password(withIdentifier: identifier)
        } catch {
            throw ManagedAppErrorMapping.coreError(error, identifier: identifier)
        }
    }
}

/// Client identity and trust anchors from managed certificates, for mutual TLS to gateways behind
/// edge proxies (use ``urlCredential()`` in a `URLSession` client-certificate challenge).
@available(iOS 18.4, visionOS 2.4, macOS 27.0, *)
public struct ManagedGatewayClientIdentity: Sendable {
    /// Managed identity identifier.
    public var identityIdentifier: String
    /// Managed certificate identifiers used as trust anchors (alternative to `tlsFingerprint` pinning).
    public var anchorCertificateIdentifiers: [String]

    /// Creates a managed client identity reference.
    /// - Parameters:
    ///   - identityIdentifier: Managed identity identifier.
    ///   - anchorCertificateIdentifiers: Managed anchor certificate identifiers.
    public init(identityIdentifier: String, anchorCertificateIdentifiers: [String] = []) {
        self.identityIdentifier = identityIdentifier
        self.anchorCertificateIdentifiers = anchorCertificateIdentifiers
    }

    /// Loads the managed identity.
    /// - Returns: The identity.
    public func identity() async throws -> SecIdentity {
        let provider = ManagedAppIdentitiesProvider()
        do {
            return try await provider.identity(withIdentifier: self.identityIdentifier)
        } catch {
            throw ManagedAppErrorMapping.coreError(error, identifier: self.identityIdentifier)
        }
    }

    /// Loads the managed anchor certificates.
    /// - Returns: Anchor certificates in identifier order.
    public func anchorCertificates() async throws -> [SecCertificate] {
        var certificates: [SecCertificate] = []
        for identifier in self.anchorCertificateIdentifiers {
            let provider = ManagedAppCertificatesProvider()
            do {
                certificates.append(try await provider.certificate(withIdentifier: identifier))
            } catch {
                throw ManagedAppErrorMapping.coreError(error, identifier: identifier)
            }
        }
        return certificates
    }

    /// A client-certificate credential for `URLSession` challenges.
    /// - Returns: The credential (identity plus anchor chain).
    public func urlCredential() async throws -> URLCredential {
        let identity = try await self.identity()
        let chain = try await self.anchorCertificates()
        return URLCredential(identity: identity, certificates: chain.isEmpty ? nil : chain, persistence: .forSession)
    }
}

/// Managed identities plug straight into ``GatewayTLSPinningSession/init(params:allowsRedirects:allowsStoredCredentials:clientIdentity:)``:
/// the session answers client-certificate challenges with ``ManagedGatewayClientIdentity/urlCredential()``
/// and adds ``ManagedGatewayClientIdentity/anchorCertificates()`` to server-trust evaluation.
@available(iOS 18.4, visionOS 2.4, macOS 27.0, *)
extension ManagedGatewayClientIdentity: GatewayClientIdentityProviding {}

@available(iOS 18.4, visionOS 2.4, macOS 27.0, *)
enum ManagedAppErrorMapping {
    static func coreError(_ error: any Error, identifier: String) -> OpenClawCoreError {
        guard let managed = error as? ManagedAppError else {
            return .unavailable("Managed app configuration failed for \"\(identifier)\": \(error.localizedDescription)")
        }
        switch managed {
        case .invalidIdentifier:
            return .invalidConfiguration("Managed identifier \"\(identifier)\" is not installed.")
        case .serverError:
            return .unavailable("Managed app configuration server error for \"\(identifier)\".")
        case .internalError:
            return .unavailable("Managed app configuration internal error for \"\(identifier)\".")
        @unknown default:
            return .unavailable("Managed app configuration failed for \"\(identifier)\".")
        }
    }
}
#endif
