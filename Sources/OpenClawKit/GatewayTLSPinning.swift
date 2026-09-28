import CryptoKit
import Foundation
import Security

/// TLS trust and pinning parameters for one gateway connection.
public struct GatewayTLSParams: Equatable, Sendable {
    /// Indicates whether TLS trust failures should reject the connection.
    public let required: Bool
    /// Expected certificate fingerprint when pinning to a known endpoint. An explicit pin (for example
    /// `gateway.remote.tlsFingerprint`) always wins and does not require system trust.
    public let expectedFingerprint: String?
    /// Enables trust-on-first-use pinning when no fingerprint is stored yet. First use now requires
    /// the certificate to pass system trust for the requested hostname before it is pinned.
    public let allowTOFU: Bool
    /// Stable storage key used when persisting and enforcing first-use fingerprints.
    public let storeKey: String?
    /// When `true`, fingerprint pinning is disabled entirely and only system trust for the requested
    /// hostname is accepted (for example Apple Watch direct mode). SDK-only extension.
    public let requiresSystemTrust: Bool

    /// Creates one set of TLS pinning parameters.
    public init(
        required: Bool,
        expectedFingerprint: String?,
        allowTOFU: Bool,
        storeKey: String?,
        requiresSystemTrust: Bool = false)
    {
        self.required = required
        self.expectedFingerprint = expectedFingerprint
        self.allowTOFU = allowTOFU
        self.storeKey = storeKey
        self.requiresSystemTrust = requiresSystemTrust
    }
}

/// Why a gateway TLS challenge was rejected.
public enum GatewayTLSValidationFailureKind: String, Sendable {
    /// The presented certificate does not match the enforced pin.
    case pinMismatch
    /// No certificate could be read from the server trust.
    case certificateUnavailable
    /// The certificate failed system trust and no pin allowed it.
    case untrustedCertificate
    /// A first-use pin could not be stored, so the connection fails closed.
    case pinStorageUnavailable
    /// The challenge came from a different host or port than the requested gateway.
    case authorityMismatch
}

/// Typed evidence for a rejected gateway TLS challenge, suitable for repair or re-trust prompts.
public struct GatewayTLSValidationFailure: Equatable, Sendable {
    /// Failure category.
    public let kind: GatewayTLSValidationFailureKind
    /// Host from the TLS challenge.
    public let host: String
    /// Pin storage key, when the connection has one.
    public let storeKey: String?
    /// Fingerprint the connection expected (explicit or stored pin), if any.
    public let expectedFingerprint: String?
    /// SHA-256 fingerprint of the presented leaf certificate, if readable.
    public let observedFingerprint: String?
    /// Whether the certificate passed system trust for the requested hostname.
    public let systemTrustOk: Bool
    /// Port from the TLS challenge.
    public let port: Int?
    /// Why system trust failed, when it did (SDK-only extension).
    public let trustFailureReason: GatewayTLSTrustFailureReason?

    /// Creates a validation failure record.
    public init(
        kind: GatewayTLSValidationFailureKind,
        host: String,
        storeKey: String?,
        expectedFingerprint: String?,
        observedFingerprint: String?,
        systemTrustOk: Bool,
        port: Int? = nil,
        trustFailureReason: GatewayTLSTrustFailureReason? = nil)
    {
        self.kind = kind
        self.host = host
        self.storeKey = storeKey
        self.expectedFingerprint = expectedFingerprint
        self.observedFingerprint = observedFingerprint
        self.systemTrustOk = systemTrustOk
        self.port = port
        self.trustFailureReason = trustFailureReason
    }
}

/// Localized error that wraps a ``GatewayTLSValidationFailure`` with caller context.
public struct GatewayTLSValidationError: LocalizedError, Sendable {
    /// Underlying typed failure.
    public let failure: GatewayTLSValidationFailure
    /// Caller context prefixed to the description (for example `gateway connect`).
    public let context: String

    /// Creates a validation error.
    public init(failure: GatewayTLSValidationFailure, context: String) {
        self.failure = failure
        self.context = context
    }

    /// Human-readable description; pin mismatches include the expected and observed SHA-256 values.
    public var errorDescription: String? {
        let prefix = self.context.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self.failure.kind {
        case .pinMismatch:
            let expected = self.failure.expectedFingerprint ?? "unknown"
            let observed = self.failure.observedFingerprint ?? "unknown"
            let mismatch = "expected \(expected), observed \(observed)"
            return "\(prefix): TLS certificate pin mismatch for \(self.failure.host) (\(mismatch))"
        case .certificateUnavailable:
            return "\(prefix): TLS certificate unavailable for \(self.failure.host)"
        case .untrustedCertificate:
            return "\(prefix): TLS certificate is not trusted for \(self.failure.host)"
        case .pinStorageUnavailable:
            return "\(prefix): TLS certificate pin could not be saved for \(self.failure.host)"
        case .authorityMismatch:
            return "\(prefix): TLS authority does not match the requested gateway for \(self.failure.host)"
        }
    }
}

/// Errors from ``GatewayTLSPinningSession/data(for:maximumBytes:isCurrent:)``.
public enum GatewayBoundedDataError: Error, Equatable, Sendable {
    /// The response body exceeded the caller's byte ceiling and was cancelled.
    case responseTooLarge(maximumBytes: Int)
}

// periphery:ignore - Native session adapters expose typed TLS repair evidence to GatewayChannel.
/// Session adapters that can report the last rejected TLS challenge.
public protocol GatewayTLSFailureProviding: AnyObject {
    // periphery:ignore - The shared channel consumes this through the optional provider seam.
    /// Returns and clears the most recent TLS validation failure.
    func consumeLastTLSFailure() -> GatewayTLSValidationFailure?
}

// periphery:ignore - Native session adapters declare whether their TLS path permits token retry.
/// Session adapters that declare whether their endpoint is trusted enough for device-token retries.
public protocol GatewayDeviceTokenRetryTrustProviding: AnyObject {
    // periphery:ignore - The shared channel consumes this through the optional provider seam.
    /// Whether the connection may retry authentication with a stored device token.
    var allowsDeviceTokenRetryAuth: Bool { get }
}

/// Supplies a TLS client identity (mutual TLS) and optional extra trust anchors to a
/// ``GatewayTLSPinningSession``, for gateways behind edge proxies that require client certificates.
///
/// `ManagedGatewayClientIdentity` (managed app configuration) conforms; hosts can supply their own.
public protocol GatewayClientIdentityProviding: Sendable {
    /// Credential answering `NSURLAuthenticationMethodClientCertificate` challenges.
    func urlCredential() async throws -> URLCredential
    /// Extra trust anchors added to server-trust evaluation (system roots stay trusted); empty for none.
    func anchorCertificates() async throws -> [SecCertificate]
}

extension GatewayClientIdentityProviding {
    /// No extra trust anchors.
    public func anchorCertificates() async throws -> [SecCertificate] {
        []
    }
}

/// Carries a URLSession challenge completion across the hop that loads the client identity.
private final class GatewayTLSChallengeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?

    init(_ handler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.handler = handler
    }

    func resume(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        let handler = self.lock.withLock { () -> ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)? in
            defer { self.handler = nil }
            return self.handler
        }
        handler?(disposition, credential)
    }
}

/// Carries a challenge's `SecTrust` across the hop that loads extra anchors.
private struct GatewayTLSTrustBox: @unchecked Sendable {
    let trust: SecTrust
}

enum GatewayTLSFirstUsePolicy {
    static func allowsFirstUsePin(systemTrustOk: Bool) -> Bool {
        systemTrustOk
    }
}

enum GatewayTLSChallengeDecision: Equatable {
    case accept(fingerprint: String?, enforcePin: Bool, saveFirstUse: Bool)
    case reject(GatewayTLSValidationFailureKind)
}

enum GatewayTLSValidationPolicy {
    static func decide(
        expectedFingerprint: String?,
        observedFingerprint: String?,
        allowTOFU: Bool,
        required: Bool,
        systemTrustOk: Bool) -> GatewayTLSChallengeDecision
    {
        if let expectedFingerprint {
            guard let observedFingerprint else {
                return .reject(.certificateUnavailable)
            }
            return observedFingerprint == expectedFingerprint
                ? .accept(fingerprint: observedFingerprint, enforcePin: true, saveFirstUse: false)
                : .reject(.pinMismatch)
        }
        if allowTOFU,
           let observedFingerprint,
           GatewayTLSFirstUsePolicy.allowsFirstUsePin(systemTrustOk: systemTrustOk)
        {
            return .accept(fingerprint: observedFingerprint, enforcePin: true, saveFirstUse: true)
        }
        if allowTOFU, required {
            return .reject(observedFingerprint == nil ? .certificateUnavailable : .untrustedCertificate)
        }
        if systemTrustOk || !required {
            return .accept(fingerprint: observedFingerprint, enforcePin: false, saveFirstUse: false)
        }
        return .reject(observedFingerprint == nil ? .certificateUnavailable : .untrustedCertificate)
    }
}

/// Coarse accept/reject outcome of ``GatewayTLSServerTrust/evaluate(trust:host:port:params:)``.
public enum GatewayTLSServerTrustDecision: Equatable, Sendable {
    /// The certificate is acceptable for the gateway.
    case accept
    /// The certificate must be rejected.
    case reject
}

enum GatewayTLSServerTrustEvaluation {
    case accept(fingerprint: String?, enforcePin: Bool)
    case reject(failure: GatewayTLSValidationFailure, enforcedFingerprint: String?)
}

/// Server-trust evaluation shared by every pinned Apple transport.
public enum GatewayTLSServerTrust {
    /// Evaluates a server trust for `host:port`: system trust uses `SecPolicyCreateSSL(true, host)`, an
    /// explicit pin (or the stored pin when params carry none) must match, and trusted first use is
    /// claimed through ``GatewayTLSStore``.
    public static func evaluate(
        trust: SecTrust,
        host: String,
        port: Int,
        params: GatewayTLSParams) -> GatewayTLSServerTrustDecision
    {
        let expectedFingerprint = params.expectedFingerprint ?? params.storeKey.flatMap {
            GatewayTLSStore.loadFingerprint(stableID: $0)
        }
        return switch self.evaluate(
            trust: trust,
            host: host,
            port: port,
            params: params,
            expectedFingerprint: expectedFingerprint)
        {
        case .accept:
            .accept
        case .reject:
            .reject
        }
    }

    static func evaluate(
        trust: SecTrust,
        host: String,
        port: Int,
        params: GatewayTLSParams,
        expectedFingerprint: String?) -> GatewayTLSServerTrustEvaluation
    {
        let hostnamePolicy = SecPolicyCreateSSL(true, host as CFString)
        var trustError: CFError?
        let systemTrustOk =
            SecTrustSetPolicies(trust, hostnamePolicy) == errSecSuccess &&
            SecTrustEvaluateWithError(trust, &trustError)
        let trustFailureReason = systemTrustOk ? nil : GatewayTLSTrustFailureReason(trustError: trustError)
        let fingerprint = certificateFingerprint(trust)
        let expected = expectedFingerprint.map(normalizeFingerprint)
        let failure: (GatewayTLSValidationFailureKind, String?, String?) -> GatewayTLSServerTrustEvaluation
        failure = { kind, expectedFingerprint, enforcedFingerprint in
            .reject(
                failure: GatewayTLSValidationFailure(
                    kind: kind,
                    host: host,
                    storeKey: params.storeKey,
                    expectedFingerprint: expectedFingerprint,
                    observedFingerprint: fingerprint,
                    systemTrustOk: systemTrustOk,
                    port: port,
                    trustFailureReason: trustFailureReason),
                enforcedFingerprint: enforcedFingerprint)
        }
        if params.requiresSystemTrust {
            // System-trust-only mode never pins or consults stored fingerprints.
            return systemTrustOk
                ? .accept(fingerprint: fingerprint, enforcePin: false)
                : failure(fingerprint == nil ? .certificateUnavailable : .untrustedCertificate, nil, nil)
        }
        switch GatewayTLSValidationPolicy.decide(
            expectedFingerprint: expected,
            observedFingerprint: fingerprint,
            allowTOFU: params.allowTOFU,
            required: params.required,
            systemTrustOk: systemTrustOk)
        {
        case let .accept(acceptedFingerprint, enforcePin, saveFirstUse):
            guard saveFirstUse else {
                return .accept(fingerprint: acceptedFingerprint, enforcePin: enforcePin)
            }
            guard let acceptedFingerprint,
                  let storeKey = params.storeKey,
                  let claimedFingerprint = GatewayTLSStore.claimFirstUseFingerprint(
                      acceptedFingerprint,
                      stableID: storeKey)
            else {
                return failure(.pinStorageUnavailable, nil, nil)
            }
            guard claimedFingerprint == acceptedFingerprint else {
                if self.promoteStagedPin(
                    observed: acceptedFingerprint,
                    current: claimedFingerprint,
                    params: params)
                {
                    return .accept(fingerprint: acceptedFingerprint, enforcePin: true)
                }
                return failure(.pinMismatch, claimedFingerprint, claimedFingerprint)
            }
            return .accept(fingerprint: acceptedFingerprint, enforcePin: enforcePin)
        case let .reject(kind):
            if kind == .pinMismatch,
               let fingerprint,
               let expected,
               self.promoteStagedPin(observed: fingerprint, current: expected, params: params)
            {
                return .accept(fingerprint: fingerprint, enforcePin: true)
            }
            return failure(kind, expected, nil)
        }
    }

    /// Promotes an operator-staged next pin when the presented certificate matches it. Explicitly
    /// configured pins (`params.expectedFingerprint`) are never rotated this way.
    private static func promoteStagedPin(
        observed: String,
        current: String,
        params: GatewayTLSParams) -> Bool
    {
        guard params.expectedFingerprint == nil,
              let storeKey = params.storeKey,
              GatewayTLSStore.stagedNextFingerprint(stableID: storeKey) == observed
        else { return false }
        return GatewayTLSStore.promoteStagedNextFingerprint(ifCurrent: current, stableID: storeKey)
    }
}

final class GatewayTLSFirstUseClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: [String: String] = [:]

    func record(_ fingerprint: String, stableID: String) {
        self.lock.lock()
        self.fingerprints[stableID] = fingerprint
        self.lock.unlock()
    }

    func fingerprint(stableID: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.fingerprints[stableID]
    }

    func clear(stableID: String) {
        self.lock.lock()
        self.fingerprints[stableID] = nil
        self.lock.unlock()
    }

    func clearAll() {
        self.lock.lock()
        self.fingerprints.removeAll()
        self.lock.unlock()
    }
}

struct GatewayTLSKeychainOperations: @unchecked Sendable {
    let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let add: (CFDictionary) -> OSStatus
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    static let live = GatewayTLSKeychainOperations(
        copyMatching: { SecItemCopyMatching($0, $1) },
        add: { SecItemAdd($0, nil) },
        update: { SecItemUpdate($0, $1) },
        delete: { SecItemDelete($0) })
}

struct GatewayTLSKeychainNamespaceState {
    private(set) var suffix: String?
    private(set) var used = false

    mutating func configure(suffix: String) -> Bool {
        if let configured = self.suffix {
            return configured == suffix
        }
        guard !self.used || suffix.isEmpty else { return false }
        self.suffix = suffix
        return true
    }

    mutating func service(base: String) -> String {
        self.used = true
        return base + (self.suffix ?? "")
    }
}

/// Keychain-backed store for persisted gateway TLS fingerprints (v3 format).
///
/// Pins live in the generic-password class under service `ai.openclaw.tls-pinning` (plus an optional
/// suffix) and account `fingerprint.v3.<base64url(stableID)>`, with the canonical value mirrored in
/// `kSecAttrGeneric` for compare-and-swap replacement. Older records (`fingerprint.v2.` accounts,
/// raw-stableID accounts written by earlier SDK releases, and the `ai.openclaw.shared` UserDefaults
/// suite) migrate on first read and are then cleared.
public enum GatewayTLSStore {
    @TaskLocal static var keychainOperations = GatewayTLSKeychainOperations.live

    private enum FingerprintRead {
        case missing
        case value(String)
        case unavailable
    }

    private static let baseKeychainService = "ai.openclaw.tls-pinning"
    private static let keychainServiceLock = NSLock()
    nonisolated(unsafe) private static var keychainNamespace = GatewayTLSKeychainNamespaceState()
    private static var keychainService: String {
        self.keychainServiceLock.withLock {
            self.keychainNamespace.service(base: self.baseKeychainService)
        }
    }

    private static var usesDefaultKeychainService: Bool {
        self.keychainServiceLock.withLock { (self.keychainNamespace.suffix ?? "").isEmpty }
    }

    private static let keychainAccountPrefix = "fingerprint.v3."
    private static let legacyCanonicalAccountPrefix = "fingerprint.v2."
    private static let stagedNextAccountPrefix = "fingerprint.next.v3."

    // Legacy UserDefaults location used before Keychain migration.
    private static let legacySuiteName = "ai.openclaw.shared"
    private static let legacyKeyPrefix = "gateway.tls."
    private static let firstUseClaims = GatewayTLSFirstUseClaims()

    /// The macOS app profile is immutable for the process lifetime. Configure its
    /// Keychain namespace before constructing any Gateway connection.
    ///
    /// - Returns: `false` when a different suffix is already configured or the default namespace was
    ///   already used.
    @discardableResult
    public static func configureKeychainServiceSuffix(_ suffix: String) -> Bool {
        self.keychainServiceLock.withLock {
            self.keychainNamespace.configure(suffix: suffix)
        }
    }

    static func resolvedKeychainService(suffix: String) -> String {
        self.baseKeychainService + suffix
    }

    /// Loads the stored fingerprint for a stable endpoint identifier, migrating legacy records.
    public static func loadFingerprint(stableID: String) -> String? {
        guard case let .value(fingerprint) = self.loadFingerprintResult(stableID: stableID) else {
            return nil
        }
        return fingerprint
    }

    /// Saves (or overwrites) the fingerprint for a stable endpoint identifier.
    public static func saveFingerprint(_ value: String, stableID: String) {
        guard self.writeCanonicalFingerprint(value, stableID: stableID) else { return }
        _ = self.clearSafeLegacyFingerprint(stableID: stableID)
    }

    static func claimFirstUseFingerprint(_ value: String, stableID: String) -> String? {
        guard let account = self.keychainAccount(stableID: stableID) else { return nil }
        switch self.loadFingerprintResult(stableID: stableID) {
        case let .value(existing):
            self.firstUseClaims.record(existing, stableID: stableID)
            return existing
        case .unavailable:
            return nil
        case .missing:
            break
        }

        let claimed = self.createCanonicalFingerprintIfAbsent(value, account: account)
        if claimed != nil {
            _ = self.clearSafeLegacyFingerprint(stableID: stableID)
        }
        if let claimed {
            self.firstUseClaims.record(claimed, stableID: stableID)
        }
        return claimed
    }

    /// Returns the fingerprint this process claimed (or adopted) as the first-use pin, if any.
    public static func claimedFirstUseFingerprint(stableID: String) -> String? {
        self.firstUseClaims.fingerprint(stableID: stableID)
    }

    /// Replaces the stored fingerprint unconditionally (for example after the user confirms a rotated
    /// certificate). Also clears legacy copies.
    @discardableResult
    public static func replaceFingerprint(_ value: String, stableID: String) -> Bool {
        guard self.writeCanonicalFingerprint(value, stableID: stableID) else { return false }
        return self.clearSafeLegacyFingerprint(stableID: stableID)
    }

    /// Replaces the stored fingerprint only when it still equals `expectedValue` (compare-and-swap).
    @discardableResult
    public static func replaceFingerprint(
        _ value: String,
        ifCurrent expectedValue: String,
        stableID: String) -> Bool
    {
        guard let account = self.keychainAccount(stableID: stableID) else { return false }
        // Migrate legacy records first so the comparison attribute exists.
        _ = self.loadFingerprintResult(stableID: stableID)
        let expectedData = Data(self.canonicalStoredFingerprint(expectedValue).utf8)
        let replacementData = Data(self.canonicalStoredFingerprint(value).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrGeneric as String: expectedData,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: replacementData,
            kSecAttrGeneric as String: replacementData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard self.keychainOperations.update(query as CFDictionary, updates as CFDictionary) == errSecSuccess else {
            return false
        }
        return self.clearSafeLegacyFingerprint(stableID: stableID)
    }

    /// Removes the stored (and legacy) fingerprint and any first-use claim for an endpoint.
    @discardableResult
    public static func clearFingerprint(stableID: String) -> Bool {
        guard let account = self.keychainAccount(stableID: stableID) else { return false }
        let removedCanonical = self.deleteFingerprint(account: account)
        let removedLegacy = self.clearSafeLegacyFingerprint(stableID: stableID)
        let removedStaged = self.keychainAccount(stableID: stableID, prefix: self.stagedNextAccountPrefix)
            .map { self.deleteFingerprint(account: $0) } ?? true
        let removed = removedCanonical && removedLegacy && removedStaged
        if removed {
            self.firstUseClaims.clear(stableID: stableID)
        }
        return removed
    }

    /// Removes every stored fingerprint (including staged next pins) and legacy UserDefaults copies.
    @discardableResult
    public static func clearAllFingerprints() -> Bool {
        let removedKeychain = self.keychainOperations.delete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
        ] as CFDictionary)
        self.clearAllLegacyFingerprints()
        let removed = removedKeychain == errSecSuccess || removedKeychain == errSecItemNotFound
        if removed {
            self.firstUseClaims.clearAll()
        }
        return removed
    }

    // MARK: - Staged rotation (SDK-only)

    /// Pre-stages the fingerprint of a renewed certificate. While a pin is enforced for the endpoint,
    /// a certificate matching the staged value is accepted once and promoted to the current pin, so
    /// operators can rotate certificates without a pin-mismatch outage.
    @discardableResult
    public static func stageNextFingerprint(_ value: String, stableID: String) -> Bool {
        guard let account = self.keychainAccount(stableID: stableID, prefix: self.stagedNextAccountPrefix) else {
            return false
        }
        return self.writeCanonicalFingerprint(value, account: account)
    }

    /// Returns the staged next fingerprint for an endpoint, if one is stored.
    public static func stagedNextFingerprint(stableID: String) -> String? {
        guard let account = self.keychainAccount(stableID: stableID, prefix: self.stagedNextAccountPrefix) else {
            return nil
        }
        return self.loadCanonicalFingerprint(account: account)
    }

    /// Removes the staged next fingerprint for an endpoint.
    @discardableResult
    public static func clearStagedNextFingerprint(stableID: String) -> Bool {
        guard let account = self.keychainAccount(stableID: stableID, prefix: self.stagedNextAccountPrefix) else {
            return false
        }
        return self.deleteFingerprint(account: account)
    }

    static func promoteStagedNextFingerprint(ifCurrent current: String, stableID: String) -> Bool {
        guard let staged = self.stagedNextFingerprint(stableID: stableID),
              self.replaceFingerprint(staged, ifCurrent: current, stableID: stableID)
        else { return false }
        _ = self.clearStagedNextFingerprint(stableID: stableID)
        self.firstUseClaims.record(staged, stableID: stableID)
        return true
    }

    // MARK: - Migration

    /// v3 stores the canonical fingerprint in both value data and a searchable
    /// comparison attribute. Older records migrate by atomically creating v3;
    /// concurrent writers always keep the first complete v3 record.
    private static func loadFingerprintResult(stableID: String) -> FingerprintRead {
        guard let account = self.keychainAccount(stableID: stableID) else { return .unavailable }
        switch self.readCanonicalFingerprint(account: account) {
        case let .value(fingerprint):
            _ = self.clearSafeLegacyFingerprint(stableID: stableID)
            return .value(fingerprint)
        case .unavailable:
            return .unavailable
        case .missing:
            return self.migrateLegacyFingerprint(stableID: stableID, account: account)
        }
    }

    private static func migrateLegacyFingerprint(
        stableID: String,
        account: String) -> FingerprintRead
    {
        let v2Account = self.keychainAccount(
            stableID: stableID,
            prefix: self.legacyCanonicalAccountPrefix)
        if let v2Account {
            switch self.readLegacyKeychainFingerprint(account: v2Account) {
            case let .value(fingerprint):
                return self.migrateLegacyFingerprint(
                    fingerprint,
                    stableID: stableID,
                    account: account)
            case .unavailable:
                return .unavailable
            case .missing:
                break
            }
        }
        guard self.canSafelyReadLegacyRawStorageKey(stableID) else { return .missing }

        switch self.readLegacyKeychainFingerprint(account: stableID) {
        case let .value(fingerprint):
            return self.migrateLegacyFingerprint(
                fingerprint,
                stableID: stableID,
                account: account)
        case .unavailable:
            return .unavailable
        case .missing:
            break
        }
        switch self.readLegacyDefaultsFingerprint(stableID: stableID) {
        case let .value(fingerprint):
            return self.migrateLegacyFingerprint(
                fingerprint,
                stableID: stableID,
                account: account)
        case .unavailable:
            return .unavailable
        case .missing:
            return .missing
        }
    }

    private static func migrateLegacyFingerprint(
        _ fingerprint: String,
        stableID: String,
        account: String) -> FingerprintRead
    {
        guard let winner = self.createCanonicalFingerprintIfAbsent(fingerprint, account: account) else {
            return .unavailable
        }
        _ = self.clearSafeLegacyFingerprint(stableID: stableID)
        return .value(winner)
    }

    private static func readCanonicalFingerprint(account: String) -> FingerprintRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = self.keychainOperations.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let comparisonData = item[kSecAttrGeneric as String] as? Data,
              let value = String(data: data, encoding: .utf8),
              let comparison = String(data: comparisonData, encoding: .utf8)
        else { return .unavailable }
        let fingerprint = self.canonicalStoredFingerprint(value)
        return comparison == fingerprint ? .value(fingerprint) : .unavailable
    }

    private static func loadCanonicalFingerprint(account: String) -> String? {
        guard case let .value(fingerprint) = self.readCanonicalFingerprint(account: account) else {
            return nil
        }
        return fingerprint
    }

    private static func readLegacyKeychainFingerprint(account: String) -> FingerprintRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = self.keychainOperations.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              let fingerprint = self.normalizedFingerprint(value)
        else { return .unavailable }
        return .value(fingerprint)
    }

    private static func readLegacyDefaultsFingerprint(stableID: String) -> FingerprintRead {
        guard self.usesDefaultKeychainService else { return .missing }
        guard let defaults = UserDefaults(suiteName: self.legacySuiteName) else { return .unavailable }
        let key = self.legacyKeyPrefix + stableID
        guard let value = defaults.object(forKey: key) else { return .missing }
        guard let raw = value as? String,
              let fingerprint = self.normalizedFingerprint(raw)
        else { return .unavailable }
        return .value(fingerprint)
    }

    private static func writeCanonicalFingerprint(_ value: String, stableID: String) -> Bool {
        guard let account = self.keychainAccount(stableID: stableID) else { return false }
        return self.writeCanonicalFingerprint(value, account: account)
    }

    private static func writeCanonicalFingerprint(_ value: String, account: String) -> Bool {
        let data = Data(self.canonicalStoredFingerprint(value).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: account,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrGeneric as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = self.keychainOperations.update(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }
        return self.createCanonicalFingerprintIfAbsent(value, account: account) != nil
    }

    private static func createCanonicalFingerprintIfAbsent(
        _ value: String,
        account: String) -> String?
    {
        let fingerprint = self.canonicalStoredFingerprint(value)
        let data = Data(fingerprint.utf8)
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrGeneric as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = self.keychainOperations.add(insert as CFDictionary)
        if addStatus == errSecSuccess {
            return fingerprint
        }
        guard addStatus == errSecDuplicateItem else { return nil }
        return self.loadCanonicalFingerprint(account: account)
    }

    private static func keychainAccount(stableID: String) -> String? {
        self.keychainAccount(stableID: stableID, prefix: self.keychainAccountPrefix)
    }

    private static func keychainAccount(stableID: String, prefix: String) -> String? {
        guard !stableID.isEmpty else { return nil }
        let component = Data(stableID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + component
    }

    private static func canSafelyReadLegacyRawStorageKey(_ stableID: String) -> Bool {
        !stableID.isEmpty &&
            !stableID.hasPrefix(self.keychainAccountPrefix) &&
            !stableID.hasPrefix(self.legacyCanonicalAccountPrefix) &&
            !stableID.hasPrefix(self.stagedNextAccountPrefix) &&
            stableID.unicodeScalars.allSatisfy(\.isASCII)
    }

    private static func canonicalStoredFingerprint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeFingerprint(trimmed)
        return normalized.count == 64 ? normalized : trimmed
    }

    private static func normalizedFingerprint(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    @discardableResult
    private static func clearSafeLegacyFingerprint(stableID: String) -> Bool {
        let removedV2 = self.keychainAccount(
            stableID: stableID,
            prefix: self.legacyCanonicalAccountPrefix).map {
            self.deleteFingerprint(account: $0)
        } ?? true
        guard self.canSafelyReadLegacyRawStorageKey(stableID) else { return removedV2 }
        let removedRaw = self.deleteFingerprint(account: stableID)
        if self.usesDefaultKeychainService {
            UserDefaults(suiteName: self.legacySuiteName)?
                .removeObject(forKey: self.legacyKeyPrefix + stableID)
        }
        return removedRaw && removedV2
    }

    private static func deleteFingerprint(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = self.keychainOperations.delete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func clearAllLegacyFingerprints() {
        guard self.usesDefaultKeychainService else { return }
        guard let defaults = UserDefaults(suiteName: self.legacySuiteName) else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(self.legacyKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Session adapters that expose the fingerprint accepted for the current route.
public protocol GatewayTLSRouteMetadataProviding: AnyObject {
    /// Lowercase 64-hex SHA-256 fingerprint of the accepted certificate, if one was accepted.
    var effectiveTLSFingerprintSHA256: String? { get }
}

/// Normalized scheme/host/port authority a pinned session is bound to.
public struct GatewayTLSAuthority: Equatable, Sendable {
    /// Lowercased scheme (`ws`, `wss`, `http` or `https`).
    public let scheme: String
    /// Lowercased host without IPv6 brackets.
    public let host: String
    /// Effective port (explicit or the scheme default).
    public let port: Int
    private let defaultPort: Int

    /// Creates an authority for `ws`, `wss`, `http` and `https` URLs with a host; `nil` otherwise.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let defaultPort = Self.defaultPort(for: scheme),
              let host = Self.normalizedHost(url.host)
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? defaultPort
        self.defaultPort = defaultPort
    }

    /// Whether a TLS challenge `host:port` targets this authority (port 0 means the scheme default).
    public func matches(host: String, port: Int) -> Bool {
        // URLProtectionSpace uses 0 for the protocol's default port. Normalize it here so
        // every pinned Apple transport reaches the same authority decision.
        let challengePort = port == 0 ? self.defaultPort : port
        return Self.normalizedHost(host) == self.host && challengePort == self.port
    }

    /// `scheme://host[:port]` with the default port omitted and IPv6 hosts bracketed.
    public var serialized: String {
        let hostPart = self.host.contains(":") ? "[\(self.host)]" : self.host
        return "\(self.scheme)://\(hostPart)" + (self.port == self.defaultPort ? "" : ":\(self.port)")
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": 80
        case "https", "wss": 443
        default: nil
        }
    }

    private static func normalizedHost(_ host: String?) -> String? {
        let value = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !value.isEmpty else { return nil }
        return value.hasPrefix("[") && value.hasSuffix("]")
            ? String(value.dropFirst().dropLast())
            : value
    }
}

struct GatewayTLSPinningState {
    private(set) var acceptedFingerprint: String?
    private(set) var enforcedFingerprint: String?

    init(expectedFingerprint: String?) {
        let expected = expectedFingerprint.map(normalizeFingerprint)
        self.enforcedFingerprint = expected
        self.acceptedFingerprint = expected.flatMap { $0.count == 64 ? $0 : nil }
    }

    mutating func enforceFingerprint(_ fingerprint: String) {
        self.enforcedFingerprint = fingerprint
    }

    mutating func recordAcceptance(_ fingerprint: String?, enforcePin: Bool) {
        guard let fingerprint else { return }
        self.acceptedFingerprint = fingerprint
        if enforcePin {
            self.enforcedFingerprint = fingerprint
        }
    }
}

/// `URLSession` wrapper that enforces gateway TLS pinning, system-trust first use and authority binding.
///
/// The first URL passed to the session fixes its expected authority; challenges from any other
/// host or port are rejected with ``GatewayTLSValidationFailureKind/authorityMismatch``.
public final class GatewayTLSPinningSession: NSObject, WebSocketSessioning, URLSessionTaskDelegate,
    GatewayTLSFailureProviding, GatewayDeviceTokenRetryTrustProviding, GatewayTLSRouteMetadataProviding,
    @unchecked Sendable
{
    private let params: GatewayTLSParams
    private let allowsRedirects: Bool
    private let allowsStoredCredentials: Bool
    private let clientIdentity: (any GatewayClientIdentityProviding)?
    private let failureLock = NSLock()
    private var lastTLSFailure: GatewayTLSValidationFailure?
    private var pinningState: GatewayTLSPinningState
    private var expectedAuthority: GatewayTLSAuthority?
    private lazy var session: URLSession = {
        let config = self.allowsStoredCredentials ? URLSessionConfiguration.default : .ephemeral
        if !self.allowsStoredCredentials {
            // Explicit per-request authority cannot inherit or persist another
            // account's cookies, HTTP credentials, or authenticated cache entries.
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
        }
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Creates a TLS-aware session.
    ///
    /// - Parameters:
    ///   - params: Pinning and trust parameters.
    ///   - allowsRedirects: Whether HTTP redirects are followed (disable for origin-bound credentials).
    ///   - allowsStoredCredentials: When `false`, uses an ephemeral configuration without cookies,
    ///     credential storage or cache.
    ///   - clientIdentity: Client certificate (mutual TLS) and extra trust anchors, for example a
    ///     `ManagedGatewayClientIdentity`; `nil` answers client-certificate challenges with default handling.
    public init(
        params: GatewayTLSParams,
        allowsRedirects: Bool = true,
        allowsStoredCredentials: Bool = true,
        clientIdentity: (any GatewayClientIdentityProviding)? = nil)
    {
        self.params = params
        self.allowsRedirects = allowsRedirects
        self.allowsStoredCredentials = allowsStoredCredentials
        self.clientIdentity = clientIdentity
        self.pinningState = GatewayTLSPinningState(expectedFingerprint: params.expectedFingerprint)
        super.init()
    }

    /// `true` once a pin is enforced for this session, so a device-token retry cannot leak to an
    /// unverified endpoint.
    public var allowsDeviceTokenRetryAuth: Bool {
        self.failureLock.lock()
        defer { self.failureLock.unlock() }
        return self.pinningState.enforcedFingerprint != nil
    }

    /// Accepted 64-hex certificate fingerprint for the current route, if any.
    public var effectiveTLSFingerprintSHA256: String? {
        self.failureLock.lock()
        defer { self.failureLock.unlock() }
        return self.pinningState.acceptedFingerprint
    }

    /// Returns and clears the most recent TLS validation failure.
    public func consumeLastTLSFailure() -> GatewayTLSValidationFailure? {
        self.failureLock.lock()
        defer { self.failureLock.unlock() }
        let failure = self.lastTLSFailure
        self.lastTLSFailure = nil
        return failure
    }

    // periphery:ignore - External TLS transports delegate trust ownership to this session.
    /// Approve the certificate from an externally hosted TLS stream before it sends HTTP headers.
    /// The existing pin owner also supplies typed repair evidence and first-use persistence.
    public func validateServerTrust(_ trust: SecTrust, for url: URL) -> Bool {
        guard let authority = GatewayTLSAuthority(url: url), authority.scheme == "wss" else { return false }
        switch GatewayTLSServerTrust.evaluate(
            trust: trust,
            host: authority.host,
            port: authority.port,
            params: self.params,
            expectedFingerprint: self.currentEnforcedFingerprint())
        {
        case let .accept(fingerprint, enforcePin):
            self.recordTLSAcceptance(fingerprint, enforcePin: enforcePin)
            return true
        case let .reject(failure, enforcedFingerprint):
            if let enforcedFingerprint { self.recordTLSPinExpectation(enforcedFingerprint) }
            self.recordTLSFailure(failure)
            return false
        }
    }

    private func recordTLSFailure(_ failure: GatewayTLSValidationFailure) {
        self.failureLock.lock()
        self.lastTLSFailure = failure
        self.failureLock.unlock()
    }

    private func currentEnforcedFingerprint() -> String? {
        self.failureLock.lock()
        defer { self.failureLock.unlock() }
        return self.pinningState.enforcedFingerprint
    }

    private func recordTLSPinExpectation(_ fingerprint: String) {
        self.failureLock.lock()
        self.pinningState.enforceFingerprint(fingerprint)
        self.failureLock.unlock()
    }

    private func recordTLSAcceptance(_ fingerprint: String?, enforcePin: Bool) {
        self.failureLock.lock()
        self.lastTLSFailure = nil
        self.pinningState.recordAcceptance(fingerprint, enforcePin: enforcePin)
        self.failureLock.unlock()
    }

    private func registerExpectedAuthority(url: URL?) {
        guard let url, let authority = GatewayTLSAuthority(url: url) else { return }
        self.failureLock.lock()
        if self.expectedAuthority == nil {
            self.expectedAuthority = authority
        }
        self.failureLock.unlock()
    }

    private func currentExpectedAuthority() -> GatewayTLSAuthority? {
        self.failureLock.lock()
        defer { self.failureLock.unlock() }
        return self.expectedAuthority
    }

    /// Creates a WebSocket task for `url` (16 MB maximum message size).
    public func makeWebSocketTask(url: URL) -> WebSocketTaskBox {
        self.makeWebSocketTask(request: URLRequest(url: url))
    }

    /// Creates a WebSocket task for `request`, keeping its headers on the upgrade request.
    public func makeWebSocketTask(request: URLRequest) -> WebSocketTaskBox {
        self.registerExpectedAuthority(url: request.url)
        let task = self.session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        return WebSocketTaskBox(task: task)
    }

    /// Fetches a response body through the pinned session, cancelling once it exceeds `maximumBytes`.
    ///
    /// - Throws: ``GatewayBoundedDataError/responseTooLarge(maximumBytes:)`` when the body is too large,
    ///   `CancellationError` when cancelled or `isCurrent()` turns false before the request starts.
    public func data(
        for request: URLRequest,
        maximumBytes: Int,
        isCurrent: @Sendable () -> Bool = { true }) async throws -> (Data, URLResponse)
    {
        self.registerExpectedAuthority(url: request.url)
        guard maximumBytes >= 0 else {
            throw GatewayBoundedDataError.responseTooLarge(maximumBytes: maximumBytes)
        }

        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        // AsyncBytes owns a task delegate; without ours, its authentication
        // handling bypasses the session-level certificate policy.
        let (bytes, response) = try await self.session.bytes(for: request, delegate: self)
        let expectedLength = response.expectedContentLength
        guard expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
            bytes.task.cancel()
            throw GatewayBoundedDataError.responseTooLarge(maximumBytes: maximumBytes)
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        return try await withTaskCancellationHandler {
            do {
                for try await byte in bytes {
                    guard data.count < maximumBytes else {
                        bytes.task.cancel()
                        throw GatewayBoundedDataError.responseTooLarge(maximumBytes: maximumBytes)
                    }
                    data.append(byte)
                }
            } catch {
                bytes.task.cancel()
                throw error
            }
            return (data, response)
        } onCancel: {
            // Cancellation after headers must also interrupt a stalled body.
            bytes.task.cancel()
        }
    }

    /// Lets in-flight tasks finish, then invalidates the underlying `URLSession`.
    public func finishTasksAndInvalidate() {
        self.session.finishTasksAndInvalidate()
    }

    /// Follows redirects only when the session allows them.
    public func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        // Browser-session headers are origin-bound credentials. Their callers
        // disable redirects so URLSession cannot forward them to a sign-in or HTTP endpoint.
        completionHandler(self.allowsRedirects ? request : nil)
    }

    /// Task-level authentication challenges use the same pinning policy as session-level ones.
    public func urlSession(
        _ session: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    /// Evaluates server-trust challenges against the expected authority and pinning policy, and
    /// answers client-certificate challenges with the configured client identity.
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            guard let clientIdentity = self.clientIdentity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let completion = GatewayTLSChallengeCompletion(completionHandler)
            Task {
                do {
                    completion.resume(.useCredential, try await clientIdentity.urlCredential())
                } catch {
                    // A required client certificate that cannot be loaded fails the handshake locally.
                    completion.resume(.cancelAuthenticationChallenge, nil)
                }
            }
            return
        }
        guard method == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        guard let clientIdentity = self.clientIdentity else {
            self.evaluateServerTrust(trust, host: host, port: port, completionHandler: completionHandler)
            return
        }
        let completion = GatewayTLSChallengeCompletion(completionHandler)
        let box = GatewayTLSTrustBox(trust: trust)
        Task {
            let anchors = (try? await clientIdentity.anchorCertificates()) ?? []
            if !anchors.isEmpty {
                // Managed anchors extend (never replace) the system roots.
                SecTrustSetAnchorCertificates(box.trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(box.trust, false)
            }
            self.evaluateServerTrust(box.trust, host: host, port: port) { disposition, credential in
                completion.resume(disposition, credential)
            }
        }
    }

    private func evaluateServerTrust(
        _ trust: SecTrust,
        host: String,
        port: Int,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let expected = self.currentEnforcedFingerprint()
        guard let expectedAuthority = self.currentExpectedAuthority(),
              expectedAuthority.matches(host: host, port: port)
        else {
            self.recordTLSFailure(GatewayTLSValidationFailure(
                kind: .authorityMismatch,
                host: host,
                storeKey: self.params.storeKey,
                expectedFingerprint: expected,
                observedFingerprint: nil,
                systemTrustOk: false,
                port: port))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch GatewayTLSServerTrust.evaluate(
            trust: trust,
            host: host,
            port: port,
            params: self.params,
            expectedFingerprint: expected)
        {
        case let .accept(fingerprint, enforcePin):
            self.recordTLSAcceptance(fingerprint, enforcePin: enforcePin)
            completionHandler(.useCredential, URLCredential(trust: trust))
        case let .reject(failure, enforcedFingerprint):
            if let enforcedFingerprint {
                self.recordTLSPinExpectation(enforcedFingerprint)
            }
            self.recordTLSFailure(failure)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private func certificateFingerprint(_ trust: SecTrust) -> String? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let cert = chain.first
    else {
        return nil
    }
    return sha256Hex(SecCertificateCopyData(cert) as Data)
}

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Strips a `sha256:` / `sha-256` prefix and every non-hex character, then lowercases.
func normalizeFingerprint(_ raw: String) -> String {
    let stripped = raw.replacingOccurrences(
        of: #"(?i)^sha-?256\s*:?\s*"#,
        with: "",
        options: .regularExpression)
    return stripped.lowercased().filter(\.isHexDigit)
}
