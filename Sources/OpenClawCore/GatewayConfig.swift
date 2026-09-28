import Foundation

public enum GatewayMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case remote
}

/// Gateway listener bind mode.
///
/// Decoding also accepts upstream host aliases: `0.0.0.0`, `::`, `[::]` and `*` mean ``lan``;
/// `127.0.0.1`, `localhost`, `::1` and `[::1]` mean ``loopback``.
public enum GatewayBindMode: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case lan
    case loopback
    case custom
    case tailnet

    /// Resolves a bind mode or host alias, accepting surrounding whitespace and any casing.
    /// - Parameter raw: Raw bind value from config.
    public init?(normalizing raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "0.0.0.0", "::", "[::]", "*":
            self = .lan
        case "127.0.0.1", "localhost", "::1", "[::1]":
            self = .loopback
        default:
            guard let mode = GatewayBindMode(rawValue: key) else {
                return nil
            }
            self = mode
        }
    }

    /// Decodes a bind mode, accepting the host aliases handled by ``init(normalizing:)``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let mode = GatewayBindMode(normalizing: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid gateway bind value: \(raw)"
            )
        }
        self = mode
    }
}

public struct GatewayControlUIConfig: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var basePath: String?
    public var root: String?
    public var allowedOrigins: [String]?
    public var dangerouslyAllowHostHeaderOriginFallback: Bool?
    public var allowInsecureAuth: Bool?
    public var dangerouslyDisableDeviceAuth: Bool?

    public init(
        enabled: Bool? = nil,
        basePath: String? = nil,
        root: String? = nil,
        allowedOrigins: [String]? = nil,
        dangerouslyAllowHostHeaderOriginFallback: Bool? = nil,
        allowInsecureAuth: Bool? = nil,
        dangerouslyDisableDeviceAuth: Bool? = nil
    ) {
        self.enabled = enabled
        self.basePath = basePath
        self.root = root
        self.allowedOrigins = allowedOrigins
        self.dangerouslyAllowHostHeaderOriginFallback = dangerouslyAllowHostHeaderOriginFallback
        self.allowInsecureAuth = allowInsecureAuth
        self.dangerouslyDisableDeviceAuth = dangerouslyDisableDeviceAuth
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case basePath
        case root
        case allowedOrigins
        case dangerouslyAllowHostHeaderOriginFallback
        case allowInsecureAuth
        case dangerouslyDisableDeviceAuth
    }

    /// Encodes the Control UI settings; the upstream projection omits the SDK-only `allowInsecureAuth`
    /// and the retired `dangerouslyDisableDeviceAuth` (decode-only upgrade input).
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let projection = encoder.userInfo[.openClawUpstreamProjection] as? Bool == true
        try container.encodeIfPresent(self.enabled, forKey: .enabled)
        try container.encodeIfPresent(self.basePath, forKey: .basePath)
        try container.encodeIfPresent(self.root, forKey: .root)
        try container.encodeIfPresent(self.allowedOrigins, forKey: .allowedOrigins)
        try container.encodeIfPresent(self.dangerouslyAllowHostHeaderOriginFallback, forKey: .dangerouslyAllowHostHeaderOriginFallback)
        if !projection {
            try container.encodeIfPresent(self.allowInsecureAuth, forKey: .allowInsecureAuth)
            try container.encodeIfPresent(self.dangerouslyDisableDeviceAuth, forKey: .dangerouslyDisableDeviceAuth)
        }
    }
}

public enum GatewayAuthMode: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case token
    case password
    case trustedProxy = "trusted-proxy"
}

public struct GatewayTrustedProxyConfig: Codable, Sendable, Equatable {
    public var userHeader: String
    public var requiredHeaders: [String]?
    public var allowUsers: [String]?
    /// Accept proxied requests arriving from loopback (2026.9.6).
    public var allowLoopback: Bool?
    /// Cloudflare Access OIDC verification (`issuer`, `providerId`, `githubAccountIdClaim`; 2026.9.6).
    public var cloudflareAccessOidc: [String: String]?
    /// Automatic device approval for proxied identities (`enabled`, `scopes`; 2026.9.6).
    public var deviceAutoApprove: GatewayDeviceAutoApproveConfig?

    public init(
        userHeader: String,
        requiredHeaders: [String]? = nil,
        allowUsers: [String]? = nil,
        allowLoopback: Bool? = nil,
        cloudflareAccessOidc: [String: String]? = nil,
        deviceAutoApprove: GatewayDeviceAutoApproveConfig? = nil
    ) {
        self.userHeader = userHeader
        self.requiredHeaders = requiredHeaders
        self.allowUsers = allowUsers
        self.allowLoopback = allowLoopback
        self.cloudflareAccessOidc = cloudflareAccessOidc
        self.deviceAutoApprove = deviceAutoApprove
    }
}

/// `gateway.auth.trustedProxy.deviceAutoApprove`.
public struct GatewayDeviceAutoApproveConfig: Codable, Sendable, Equatable {
    /// Enables auto-approval (default `false`).
    public var enabled: Bool?
    /// Scopes granted to auto-approved devices.
    public var scopes: [String]?

    /// Creates device auto-approval settings.
    /// - Parameters:
    ///   - enabled: Enables auto-approval.
    ///   - scopes: Granted scopes.
    public init(enabled: Bool? = nil, scopes: [String]? = nil) {
        self.enabled = enabled
        self.scopes = scopes
    }
}

/// Shared-secret hygiene for gateway token/password auth (upstream 2026.9.3–9.4 "one Gateway secret").
///
/// Upstream accepts the shared secret in either the `token` or the `password` connect field and
/// rejects blank and well-known placeholder values. Clients send the secret as `auth.token` by default
/// (older password-mode gateways need `auth.password`); servers compare `token ?? password` in token
/// mode and `password ?? token` in password mode, in constant time (``constantTimeEquals(_:_:)``).
public enum GatewaySharedSecretPolicy {
    /// Recommended minimum secret length; shorter secrets produce a warning.
    public static let minimumRecommendedLength = 16

    /// Known placeholder values (compared case-insensitively after trimming).
    public static let placeholderValues: Set<String> = [
        "changeme", "change-me", "change_me", "password", "passw0rd", "secret", "token", "your-token", "your_token",
        "yourtoken", "your-password", "your_password", "your-secret", "your-gateway-token", "your-gateway-password",
        "<token>", "<password>", "<secret>", "replace-me", "replaceme", "example", "example-token", "test", "admin",
        "openclaw", "default", "xxx", "xxxx", "xxxxx", "12345", "123456", "12345678", "1234567890", "qwerty",
        ConfigRedaction.sentinel.lowercased(),
    ]

    /// Result of evaluating a shared secret.
    public enum Strength: String, Sendable, Equatable {
        /// Blank or a known placeholder (rejected).
        case placeholder
        /// Shorter than ``minimumRecommendedLength`` (warned).
        case weak
        /// Acceptable.
        case acceptable
    }

    /// Evaluates a plaintext shared secret.
    /// - Parameter secret: Secret value.
    /// - Returns: Placeholder, weak or acceptable.
    public static func evaluate(_ secret: String) -> Strength {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || self.placeholderValues.contains(trimmed.lowercased()) || ConfigRedaction.isRedactedSecretValue(trimmed) {
            return .placeholder
        }
        if trimmed.count < self.minimumRecommendedLength {
            return .weak
        }
        return .acceptable
    }

    /// Whether the secret is blank or a known placeholder.
    /// - Parameter secret: Secret value.
    /// - Returns: `true` when the secret must be rejected.
    public static func isPlaceholder(_ secret: String) -> Bool {
        self.evaluate(secret) == .placeholder
    }

    /// Compares two secrets without early exit on the first mismatching byte.
    /// - Parameters:
    ///   - lhs: First secret.
    ///   - rhs: Second secret.
    /// - Returns: `true` when both are byte-for-byte equal.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let length = max(left.count, right.count)
        for index in 0..<length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0 && left.count == right.count
    }

    /// The connect secret a server should compare: in token mode `token ?? password`, in password mode
    /// `password ?? token` (either client field may carry the single shared secret).
    /// - Parameters:
    ///   - mode: Configured auth mode.
    ///   - token: Client `auth.token`.
    ///   - password: Client `auth.password`.
    /// - Returns: The presented secret, if any.
    public static func presentedSecret(mode: GatewayAuthMode, token: String?, password: String?) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        switch mode {
        case .password:
            return nonEmpty(password) ?? nonEmpty(token)
        default:
            return nonEmpty(token) ?? nonEmpty(password)
        }
    }
}

public struct GatewayAuthRateLimitConfig: Codable, Sendable, Equatable {
    public var maxAttempts: Int?
    public var windowMs: Int?
    public var lockoutMs: Int?
    public var exemptLoopback: Bool?

    public init(
        maxAttempts: Int? = nil,
        windowMs: Int? = nil,
        lockoutMs: Int? = nil,
        exemptLoopback: Bool? = nil
    ) {
        self.maxAttempts = maxAttempts
        self.windowMs = windowMs
        self.lockoutMs = lockoutMs
        self.exemptLoopback = exemptLoopback
    }
}

public struct GatewayAuthConfig: Codable, Sendable, Equatable {
    public var mode: GatewayAuthMode
    public var token: SecretInput?
    public var password: SecretInput?
    public var allowTailscale: Bool?
    public var rateLimit: GatewayAuthRateLimitConfig?
    public var trustedProxy: GatewayTrustedProxyConfig?
    /// Operator scopes granted per trusted identity (`gateway.auth.identityScopes`, 2026.9.6).
    public var identityScopes: [String: [String]]?

    public init(
        mode: GatewayAuthMode = .token,
        token: SecretInput? = nil,
        password: SecretInput? = nil,
        allowTailscale: Bool? = nil,
        rateLimit: GatewayAuthRateLimitConfig? = nil,
        trustedProxy: GatewayTrustedProxyConfig? = nil,
        identityScopes: [String: [String]]? = nil
    ) {
        self.mode = mode
        self.token = token
        self.password = password
        self.allowTailscale = allowTailscale
        self.rateLimit = rateLimit
        self.trustedProxy = trustedProxy
        self.identityScopes = identityScopes
    }

    public static func plaintext(
        mode: GatewayAuthMode = .token,
        token: String? = nil,
        password: String? = nil,
        allowTailscale: Bool? = nil,
        rateLimit: GatewayAuthRateLimitConfig? = nil,
        trustedProxy: GatewayTrustedProxyConfig? = nil
    ) -> GatewayAuthConfig {
        GatewayAuthConfig(
            mode: mode,
            token: token.map(SecretInput.string),
            password: password.map(SecretInput.string),
            allowTailscale: allowTailscale,
            rateLimit: rateLimit,
            trustedProxy: trustedProxy
        )
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case token
        case password
        case allowTailscale
        case identityScopes
        case rateLimit
        case trustedProxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = container.decodeLenient(GatewayAuthMode.self, forKey: .mode) ?? .token
        self.token = try container.decodeIfPresent(SecretInput.self, forKey: .token)
        self.password = try container.decodeIfPresent(SecretInput.self, forKey: .password)
        self.allowTailscale = try container.decodeIfPresent(Bool.self, forKey: .allowTailscale)
        self.rateLimit = try container.decodeIfPresent(GatewayAuthRateLimitConfig.self, forKey: .rateLimit)
        self.trustedProxy = try container.decodeIfPresent(GatewayTrustedProxyConfig.self, forKey: .trustedProxy)
        self.identityScopes = container.decodeLenient([String: [String]].self, forKey: .identityScopes)
    }

    /// Encodes the auth block (`mode` is always written).
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.mode, forKey: .mode)
        try container.encodeIfPresent(self.token, forKey: .token)
        try container.encodeIfPresent(self.password, forKey: .password)
        try container.encodeIfPresent(self.allowTailscale, forKey: .allowTailscale)
        try container.encodeIfPresent(self.identityScopes, forKey: .identityScopes)
        try container.encodeIfPresent(self.rateLimit, forKey: .rateLimit)
        try container.encodeIfPresent(self.trustedProxy, forKey: .trustedProxy)
    }

    /// The single shared secret: `token` in token mode, `password` in password mode, falling back to the
    /// other field (upstream accepts the secret in either field since 2026.9.3).
    public var sharedSecret: SecretInput? {
        switch self.mode {
        case .password:
            return self.password ?? self.token
        default:
            return self.token ?? self.password
        }
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        if self.mode == .trustedProxy {
            let userHeader = self.trustedProxy?.userHeader.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if userHeader.isEmpty {
                errors.append("gateway.auth.trustedProxy.userHeader is required when auth.mode is trusted-proxy.")
            }
        }
        if self.mode == .token || self.mode == .password,
           let secret = self.sharedSecret?.stringValue,
           GatewaySharedSecretPolicy.isPlaceholder(secret)
        {
            errors.append("gateway.auth \(self.mode.rawValue) must not be blank or a placeholder value.")
        }
        return errors
    }
}

public enum GatewayTailscaleMode: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case serve
    case funnel
}

public struct GatewayTailscaleConfig: Codable, Sendable, Equatable {
    public var mode: GatewayTailscaleMode?
    public var resetOnExit: Bool?
    /// Keep Funnel routes across restarts (deprecated upstream).
    public var preserveFunnel: Bool?

    public init(
        mode: GatewayTailscaleMode? = nil,
        resetOnExit: Bool? = nil,
        preserveFunnel: Bool? = nil
    ) {
        self.mode = mode
        self.resetOnExit = resetOnExit
        self.preserveFunnel = preserveFunnel
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case resetOnExit
        case preserveFunnel
    }

    /// Encodes the block; the upstream projection drops the retired `resetOnExit`.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.mode, forKey: .mode)
        if encoder.userInfo[.openClawUpstreamProjection] as? Bool != true {
            try container.encodeIfPresent(self.resetOnExit, forKey: .resetOnExit)
        }
        try container.encodeIfPresent(self.preserveFunnel, forKey: .preserveFunnel)
    }
}

public enum GatewayRemoteTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case ssh
    case direct
}

/// SSH host-key policy for SSH-tunnelled remote gateways.
public enum GatewaySSHHostKeyPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    /// Require a known host key.
    case strict
    /// Defer to OpenSSH's own host-key handling.
    case openssh
}

public struct GatewayRemoteConfig: Codable, Sendable, Equatable {
    /// SDK-only toggle (never written into an upstream projection).
    public var enabled: Bool?
    public var url: String?
    public var transport: GatewayRemoteTransport?
    /// Remote gateway port reached through an SSH tunnel.
    public var remotePort: Int?
    public var token: SecretInput?
    public var password: SecretInput?
    /// Extra headers presented to edge proxies in front of the gateway (values are secrets).
    public var edgeAuth: [String: SecretInput]?
    public var tlsFingerprint: String?
    public var sshTarget: String?
    public var sshIdentity: String?
    /// SSH host-key policy.
    public var sshHostKeyPolicy: GatewaySSHHostKeyPolicy?

    public init(
        enabled: Bool? = nil,
        url: String? = nil,
        transport: GatewayRemoteTransport? = nil,
        token: SecretInput? = nil,
        password: SecretInput? = nil,
        tlsFingerprint: String? = nil,
        sshTarget: String? = nil,
        sshIdentity: String? = nil,
        remotePort: Int? = nil,
        edgeAuth: [String: SecretInput]? = nil,
        sshHostKeyPolicy: GatewaySSHHostKeyPolicy? = nil
    ) {
        self.enabled = enabled
        self.url = url
        self.transport = transport
        self.remotePort = remotePort
        self.token = token
        self.password = password
        self.edgeAuth = edgeAuth
        self.tlsFingerprint = tlsFingerprint
        self.sshTarget = sshTarget
        self.sshIdentity = sshIdentity
        self.sshHostKeyPolicy = sshHostKeyPolicy
    }

    public static func plaintext(
        enabled: Bool? = nil,
        url: String? = nil,
        transport: GatewayRemoteTransport? = nil,
        token: String? = nil,
        password: String? = nil,
        tlsFingerprint: String? = nil,
        sshTarget: String? = nil,
        sshIdentity: String? = nil
    ) -> GatewayRemoteConfig {
        GatewayRemoteConfig(
            enabled: enabled,
            url: url,
            transport: transport,
            token: token.map(SecretInput.string),
            password: password.map(SecretInput.string),
            tlsFingerprint: tlsFingerprint,
            sshTarget: sshTarget,
            sshIdentity: sshIdentity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case url
        case transport
        case remotePort
        case token
        case password
        case edgeAuth
        case tlsFingerprint
        case sshTarget
        case sshIdentity
        case sshHostKeyPolicy
    }

    /// Decodes the remote block leniently (unknown transports and policies become `nil` plus an issue).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = container.decodeLenient(Bool.self, forKey: .enabled)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.transport = container.decodeLenient(GatewayRemoteTransport.self, forKey: .transport)
        self.remotePort = container.decodeLenient(Int.self, forKey: .remotePort)
        self.token = try container.decodeIfPresent(SecretInput.self, forKey: .token)
        self.password = try container.decodeIfPresent(SecretInput.self, forKey: .password)
        self.edgeAuth = container.decodeLossyDictionaryIfPresent(SecretInput.self, forKey: .edgeAuth)
        self.tlsFingerprint = try container.decodeIfPresent(String.self, forKey: .tlsFingerprint)
        self.sshTarget = try container.decodeIfPresent(String.self, forKey: .sshTarget)
        self.sshIdentity = try container.decodeIfPresent(String.self, forKey: .sshIdentity)
        self.sshHostKeyPolicy = container.decodeLenient(GatewaySSHHostKeyPolicy.self, forKey: .sshHostKeyPolicy)
    }

    /// Encodes the remote block; the upstream projection omits the SDK-only `enabled`.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if encoder.userInfo[.openClawUpstreamProjection] as? Bool != true {
            try container.encodeIfPresent(self.enabled, forKey: .enabled)
        }
        try container.encodeIfPresent(self.url, forKey: .url)
        try container.encodeIfPresent(self.transport, forKey: .transport)
        try container.encodeIfPresent(self.remotePort, forKey: .remotePort)
        try container.encodeIfPresent(self.token, forKey: .token)
        try container.encodeIfPresent(self.password, forKey: .password)
        try container.encodeIfPresent(self.edgeAuth, forKey: .edgeAuth)
        try container.encodeIfPresent(self.tlsFingerprint, forKey: .tlsFingerprint)
        try container.encodeIfPresent(self.sshTarget, forKey: .sshTarget)
        try container.encodeIfPresent(self.sshIdentity, forKey: .sshIdentity)
        try container.encodeIfPresent(self.sshHostKeyPolicy, forKey: .sshHostKeyPolicy)
    }

    /// Upstream `findEdgeAuthIssue`: non-empty map, RFC 7230 token header names, no transport-owned
    /// headers, and no names that differ only by case.
    /// - Returns: The first problem, or `nil` when `edgeAuth` is absent or valid.
    public func edgeAuthValidationError() -> String? {
        guard let edgeAuth else { return nil }
        return GatewayEdgeAuthHeaders.validationError(edgeAuth.keys.sorted())
    }
}

/// Header-name rules for `gateway.remote.edgeAuth` (port of `src/shared/gateway-edge-auth-headers.ts`).
public enum GatewayEdgeAuthHeaders {
    /// Headers the WebSocket transport owns and edge auth must not set.
    public static let transportOwnedHeaders: Set<String> = [
        "host", "connection", "upgrade", "content-length",
        "sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol", "sec-websocket-extensions",
    ]

    private static let tokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Validates edge-auth header names.
    /// - Parameter names: Header names in authored order.
    /// - Returns: The first problem, or `nil` when valid.
    public static func validationError(_ names: [String]) -> String? {
        guard !names.isEmpty else {
            return "invalid gateway.remote.edgeAuth: header map must not be empty"
        }
        var seen: [String: String] = [:]
        for name in names {
            guard !name.isEmpty, name.allSatisfy({ self.tokenCharacters.contains($0) }) else {
                return "invalid gateway.remote.edgeAuth header name: \"\(name)\""
            }
            let normalized = name.lowercased()
            if self.transportOwnedHeaders.contains(normalized) {
                return "gateway.remote.edgeAuth cannot set transport-owned header \"\(name)\""
            }
            if let original = seen[normalized] {
                return "gateway.remote.edgeAuth header names \"\(original)\" and \"\(name)\" differ only by case"
            }
            seen[normalized] = name
        }
        return nil
    }
}

public struct GatewayHTTPChatCompletionsImagesConfig: Codable, Sendable, Equatable {
    public var allowURL: Bool?
    public var urlAllowlist: [String]?
    public var allowedMIMEs: [String]?
    public var maxBytes: Int?
    public var maxRedirects: Int?
    public var timeoutMs: Int?

    public init(
        allowURL: Bool? = nil,
        urlAllowlist: [String]? = nil,
        allowedMIMEs: [String]? = nil,
        maxBytes: Int? = nil,
        maxRedirects: Int? = nil,
        timeoutMs: Int? = nil
    ) {
        self.allowURL = allowURL
        self.urlAllowlist = urlAllowlist
        self.allowedMIMEs = allowedMIMEs
        self.maxBytes = maxBytes
        self.maxRedirects = maxRedirects
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case allowURL = "allowUrl"
        case urlAllowlist
        case allowedMIMEs = "allowedMimes"
        case maxBytes
        case maxRedirects
        case timeoutMs
    }
}

public struct GatewayHTTPChatCompletionsConfig: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var maxBodyBytes: Int?
    public var maxImageParts: Int?
    public var maxTotalImageBytes: Int?
    public var images: GatewayHTTPChatCompletionsImagesConfig?

    public init(
        enabled: Bool? = nil,
        maxBodyBytes: Int? = nil,
        maxImageParts: Int? = nil,
        maxTotalImageBytes: Int? = nil,
        images: GatewayHTTPChatCompletionsImagesConfig? = nil
    ) {
        self.enabled = enabled
        self.maxBodyBytes = maxBodyBytes
        self.maxImageParts = maxImageParts
        self.maxTotalImageBytes = maxTotalImageBytes
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxBodyBytes
        case maxImageParts
        case maxTotalImageBytes
        case images
    }

    /// Encodes the endpoint; the upstream projection drops the retired body/image size limits.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.enabled, forKey: .enabled)
        if encoder.userInfo[.openClawUpstreamProjection] as? Bool != true {
            try container.encodeIfPresent(self.maxBodyBytes, forKey: .maxBodyBytes)
            try container.encodeIfPresent(self.maxImageParts, forKey: .maxImageParts)
            try container.encodeIfPresent(self.maxTotalImageBytes, forKey: .maxTotalImageBytes)
        }
        try container.encodeIfPresent(self.images, forKey: .images)
    }
}

public struct GatewayHTTPResponsesPDFConfig: Codable, Sendable, Equatable {
    public var maxPages: Int?
    public var maxPixels: Int?
    public var minTextChars: Int?

    public init(
        maxPages: Int? = nil,
        maxPixels: Int? = nil,
        minTextChars: Int? = nil
    ) {
        self.maxPages = maxPages
        self.maxPixels = maxPixels
        self.minTextChars = minTextChars
    }
}

public struct GatewayHTTPResponsesFilesConfig: Codable, Sendable, Equatable {
    public var allowURL: Bool?
    public var urlAllowlist: [String]?
    public var allowedMIMEs: [String]?
    public var maxBytes: Int?
    public var maxChars: Int?
    public var maxRedirects: Int?
    public var timeoutMs: Int?
    public var pdf: GatewayHTTPResponsesPDFConfig?

    public init(
        allowURL: Bool? = nil,
        urlAllowlist: [String]? = nil,
        allowedMIMEs: [String]? = nil,
        maxBytes: Int? = nil,
        maxChars: Int? = nil,
        maxRedirects: Int? = nil,
        timeoutMs: Int? = nil,
        pdf: GatewayHTTPResponsesPDFConfig? = nil
    ) {
        self.allowURL = allowURL
        self.urlAllowlist = urlAllowlist
        self.allowedMIMEs = allowedMIMEs
        self.maxBytes = maxBytes
        self.maxChars = maxChars
        self.maxRedirects = maxRedirects
        self.timeoutMs = timeoutMs
        self.pdf = pdf
    }

    private enum CodingKeys: String, CodingKey {
        case allowURL = "allowUrl"
        case urlAllowlist
        case allowedMIMEs = "allowedMimes"
        case maxBytes
        case maxChars
        case maxRedirects
        case timeoutMs
        case pdf
    }
}

public struct GatewayHTTPResponsesImagesConfig: Codable, Sendable, Equatable {
    public var allowURL: Bool?
    public var urlAllowlist: [String]?
    public var allowedMIMEs: [String]?
    public var maxBytes: Int?
    public var maxRedirects: Int?
    public var timeoutMs: Int?

    public init(
        allowURL: Bool? = nil,
        urlAllowlist: [String]? = nil,
        allowedMIMEs: [String]? = nil,
        maxBytes: Int? = nil,
        maxRedirects: Int? = nil,
        timeoutMs: Int? = nil
    ) {
        self.allowURL = allowURL
        self.urlAllowlist = urlAllowlist
        self.allowedMIMEs = allowedMIMEs
        self.maxBytes = maxBytes
        self.maxRedirects = maxRedirects
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case allowURL = "allowUrl"
        case urlAllowlist
        case allowedMIMEs = "allowedMimes"
        case maxBytes
        case maxRedirects
        case timeoutMs
    }
}

public struct GatewayHTTPResponsesConfig: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var maxBodyBytes: Int?
    public var maxURLParts: Int?
    public var files: GatewayHTTPResponsesFilesConfig?
    public var images: GatewayHTTPResponsesImagesConfig?

    public init(
        enabled: Bool? = nil,
        maxBodyBytes: Int? = nil,
        maxURLParts: Int? = nil,
        files: GatewayHTTPResponsesFilesConfig? = nil,
        images: GatewayHTTPResponsesImagesConfig? = nil
    ) {
        self.enabled = enabled
        self.maxBodyBytes = maxBodyBytes
        self.maxURLParts = maxURLParts
        self.files = files
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxBodyBytes
        case maxURLParts = "maxUrlParts"
        case files
        case images
    }

    /// Encodes the endpoint; the upstream projection drops the retired `maxBodyBytes`.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.enabled, forKey: .enabled)
        if encoder.userInfo[.openClawUpstreamProjection] as? Bool != true {
            try container.encodeIfPresent(self.maxBodyBytes, forKey: .maxBodyBytes)
        }
        try container.encodeIfPresent(self.maxURLParts, forKey: .maxURLParts)
        try container.encodeIfPresent(self.files, forKey: .files)
        try container.encodeIfPresent(self.images, forKey: .images)
    }
}

public struct GatewayHTTPEndpointsConfig: Codable, Sendable, Equatable {
    public var chatCompletions: GatewayHTTPChatCompletionsConfig?
    public var responses: GatewayHTTPResponsesConfig?

    public init(
        chatCompletions: GatewayHTTPChatCompletionsConfig? = nil,
        responses: GatewayHTTPResponsesConfig? = nil
    ) {
        self.chatCompletions = chatCompletions
        self.responses = responses
    }
}

public struct GatewayHTTPSecurityHeadersConfig: Codable, Sendable, Equatable {
    public var strictTransportSecurity: String?

    public init(strictTransportSecurity: String? = nil) {
        self.strictTransportSecurity = strictTransportSecurity
    }
}

public struct GatewayHTTPConfig: Codable, Sendable, Equatable {
    public var endpoints: GatewayHTTPEndpointsConfig?
    public var securityHeaders: GatewayHTTPSecurityHeadersConfig?

    public init(
        endpoints: GatewayHTTPEndpointsConfig? = nil,
        securityHeaders: GatewayHTTPSecurityHeadersConfig? = nil
    ) {
        self.endpoints = endpoints
        self.securityHeaders = securityHeaders
    }
}

public struct GatewayPushAPNsRelayConfig: Codable, Sendable, Equatable {
    public var baseURL: String?
    public var timeoutMs: Int?

    public init(
        baseURL: String? = nil,
        timeoutMs: Int? = nil
    ) {
        self.baseURL = baseURL
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case timeoutMs
    }
}

public struct GatewayPushAPNsConfig: Codable, Sendable, Equatable {
    public var relay: GatewayPushAPNsRelayConfig?

    public init(relay: GatewayPushAPNsRelayConfig? = nil) {
        self.relay = relay
    }
}

public struct GatewayPushConfig: Codable, Sendable, Equatable {
    public var apns: GatewayPushAPNsConfig?

    public init(apns: GatewayPushAPNsConfig? = nil) {
        self.apns = apns
    }
}

/// `gateway.nodes.commands` allow/deny lists (node command ids).
public struct GatewayNodeCommandsConfig: Codable, Sendable, Equatable {
    /// Allowed node commands.
    public var allow: [String]?
    /// Denied node commands (deny wins).
    public var deny: [String]?

    /// Creates node command policy.
    /// - Parameters:
    ///   - allow: Allowed commands.
    ///   - deny: Denied commands.
    public init(allow: [String]? = nil, deny: [String]? = nil) {
        self.allow = allow
        self.deny = deny
    }
}

/// `gateway.nodes` subset the SDK uses (pairing and browser settings pass through the document model).
public struct GatewayNodesConfig: Codable, Sendable, Equatable {
    /// Allow skills on nodes (default `true`).
    public var allowSkills: Bool?
    /// Node command allow/deny lists.
    public var commands: GatewayNodeCommandsConfig?

    /// Creates node settings.
    /// - Parameters:
    ///   - allowSkills: Allow skills on nodes.
    ///   - commands: Node command policy.
    public init(allowSkills: Bool? = nil, commands: GatewayNodeCommandsConfig? = nil) {
        self.allowSkills = allowSkills
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case allowSkills
        case commands
        case allowCommands
        case denyCommands
        case skills
    }

    /// Decodes node settings, accepting the retired `allowCommands`/`denyCommands` and
    /// `skills.enabled` spellings (canonical keys win).
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var commands = container.decodeLenient(GatewayNodeCommandsConfig.self, forKey: .commands)
        let legacyAllow = container.decodeLenient([String].self, forKey: .allowCommands)
        let legacyDeny = container.decodeLenient([String].self, forKey: .denyCommands)
        if legacyAllow != nil || legacyDeny != nil {
            var merged = commands ?? GatewayNodeCommandsConfig()
            merged.allow = merged.allow ?? legacyAllow
            merged.deny = merged.deny ?? legacyDeny
            commands = merged
            container.recordConfigIssue(
                "gateway.nodes.allowCommands/denyCommands moved to gateway.nodes.commands.allow/deny.",
                kind: .legacyKey,
                forKey: legacyDeny != nil ? .denyCommands : .allowCommands
            )
        }
        self.commands = commands
        let legacySkills = container.decodeLenient([String: Bool].self, forKey: .skills)?["enabled"]
        self.allowSkills = container.decodeLenient(Bool.self, forKey: .allowSkills) ?? legacySkills
    }

    /// Encodes the canonical keys only.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.allowSkills, forKey: .allowSkills)
        try container.encodeIfPresent(self.commands, forKey: .commands)
    }
}

/// Gateway config reload mode (`off` | `hybrid`; retired `restart`/`hot` decode as `hybrid`).
public enum GatewayReloadMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// No automatic reload.
    case off
    /// Hot-apply where possible, restart otherwise.
    case hybrid

    /// Decodes a reload mode, mapping the retired `restart` and `hot` values to ``hybrid``.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "off":
            self = .off
        case "hybrid", "restart", "hot":
            self = .hybrid
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid gateway reload mode: \(raw)")
        }
    }
}

public struct GatewayConfig: Codable, Sendable, Equatable {
    /// Default gateway listener port.
    public static let defaultPort = 18_789
    /// Environment variable that overrides ``handshakeTimeoutMs``.
    public static let handshakeTimeoutEnvironmentKey = "OPENCLAW_HANDSHAKE_TIMEOUT_MS"

    /// SDK-only listener host (never written into an upstream projection; upstream uses `bind`).
    public var host: String
    public var port: Int
    /// SDK-only legacy auth mode mirror (upstream uses `auth.mode`).
    public var authMode: String
    public var mode: GatewayMode
    public var bind: GatewayBindMode
    public var customBindHost: String?
    /// Bare HTTPS origin the gateway is reachable at (HTTP only for loopback hosts; 2026.9.6).
    public var publicOrigin: String?
    public var controlUi: GatewayControlUIConfig?
    public var auth: GatewayAuthConfig
    public var tailscale: GatewayTailscaleConfig?
    public var remote: GatewayRemoteConfig?
    /// Config reload mode.
    public var reload: GatewayReloadMode?
    public var http: GatewayHTTPConfig?
    public var push: GatewayPushConfig?
    /// Node commands and skills.
    public var nodes: GatewayNodesConfig?
    public var trustedProxies: [String]
    public var allowRealIpFallback: Bool
    /// SDK-only channel health interval (retired upstream; never written into an upstream projection).
    public var channelHealthCheckMinutes: Int
    /// SDK-local connect handshake timeout; `OPENCLAW_HANDSHAKE_TIMEOUT_MS` wins (retired upstream key).
    public var handshakeTimeoutMs: Int?

    public init(
        host: String = "127.0.0.1",
        port: Int = 18_789,
        authMode: String = GatewayAuthMode.token.rawValue,
        mode: GatewayMode = .local,
        bind: GatewayBindMode? = nil,
        customBindHost: String? = nil,
        controlUi: GatewayControlUIConfig? = nil,
        auth: GatewayAuthConfig? = nil,
        tailscale: GatewayTailscaleConfig? = nil,
        remote: GatewayRemoteConfig? = nil,
        http: GatewayHTTPConfig? = nil,
        push: GatewayPushConfig? = nil,
        trustedProxies: [String] = [],
        allowRealIpFallback: Bool = false,
        channelHealthCheckMinutes: Int = 5,
        publicOrigin: String? = nil,
        reload: GatewayReloadMode? = nil,
        nodes: GatewayNodesConfig? = nil,
        handshakeTimeoutMs: Int? = nil
    ) {
        self.publicOrigin = publicOrigin?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reload = reload
        self.nodes = nodes
        self.handshakeTimeoutMs = handshakeTimeoutMs.map { max(1, $0) }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedBind = bind ?? Self.deriveBind(from: normalizedHost)
        let normalizedAuth = auth ?? GatewayAuthConfig(
            mode: GatewayAuthMode(rawValue: authMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .token,
            token: nil as SecretInput?,
            password: nil as SecretInput?
        )

        self.host = normalizedHost.isEmpty ? "127.0.0.1" : normalizedHost
        self.port = min(max(1, port), 65_535)
        self.authMode = normalizedAuth.mode.rawValue
        self.mode = mode
        self.bind = derivedBind
        self.customBindHost = customBindHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.controlUi = controlUi
        self.auth = normalizedAuth
        self.tailscale = tailscale
        self.remote = remote
        self.http = http
        self.push = push
        self.trustedProxies = trustedProxies
        self.allowRealIpFallback = allowRealIpFallback
        self.channelHealthCheckMinutes = max(0, channelHealthCheckMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case authMode
        case mode
        case bind
        case customBindHost
        case publicOrigin
        case controlUi
        case auth
        case trustedProxies
        case allowRealIpFallback
        case tailscale
        case remote
        case reload
        case http
        case push
        case nodes
        case channelHealthCheckMinutes
        case handshakeTimeoutMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 18_789
        let mode = container.decodeLenient(GatewayMode.self, forKey: .mode) ?? .local
        let decodedAuth = try container.decodeIfPresent(GatewayAuthConfig.self, forKey: .auth)
        let legacyAuthMode = try container.decodeIfPresent(String.self, forKey: .authMode)
        let normalizedAuth = decodedAuth
            ?? GatewayAuthConfig(
                mode: GatewayAuthMode(rawValue: legacyAuthMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") ?? .token,
                token: nil as SecretInput?,
                password: nil as SecretInput?
            )

        self.init(
            host: host,
            port: port,
            authMode: decodedAuth?.mode.rawValue ?? legacyAuthMode ?? GatewayAuthMode.token.rawValue,
            mode: mode,
            bind: container.decodeLenient(GatewayBindMode.self, forKey: .bind),
            customBindHost: try container.decodeIfPresent(String.self, forKey: .customBindHost),
            controlUi: try container.decodeIfPresent(GatewayControlUIConfig.self, forKey: .controlUi),
            auth: normalizedAuth,
            tailscale: container.decodeLenient(GatewayTailscaleConfig.self, forKey: .tailscale),
            remote: try container.decodeIfPresent(GatewayRemoteConfig.self, forKey: .remote),
            http: try container.decodeIfPresent(GatewayHTTPConfig.self, forKey: .http),
            push: try container.decodeIfPresent(GatewayPushConfig.self, forKey: .push),
            trustedProxies: try container.decodeIfPresent([String].self, forKey: .trustedProxies) ?? [],
            allowRealIpFallback: try container.decodeIfPresent(Bool.self, forKey: .allowRealIpFallback) ?? false,
            channelHealthCheckMinutes: try container.decodeIfPresent(Int.self, forKey: .channelHealthCheckMinutes) ?? 5,
            publicOrigin: container.decodeLenient(String.self, forKey: .publicOrigin),
            reload: Self.decodeReloadMode(container),
            nodes: container.decodeLenient(GatewayNodesConfig.self, forKey: .nodes),
            handshakeTimeoutMs: container.decodeLenient(Int.self, forKey: .handshakeTimeoutMs)
        )
    }

    private static func decodeReloadMode(_ container: KeyedDecodingContainer<CodingKeys>) -> GatewayReloadMode? {
        struct ReloadBlock: Decodable {
            var mode: GatewayReloadMode?
        }
        return container.decodeLenient(ReloadBlock.self, forKey: .reload)?.mode
    }

    /// Encodes the gateway block.
    ///
    /// SDK-native files keep every key. With ``Swift/CodingUserInfoKey/openClawUpstreamProjection`` the
    /// SDK-only keys (`host`, `authMode`), the retired `channelHealthCheckMinutes`/`handshakeTimeoutMs`,
    /// and default-valued `trustedProxies`/`allowRealIpFallback` are omitted so the output validates
    /// against the strict upstream `gateway` schema.
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let projection = encoder.userInfo[.openClawUpstreamProjection] as? Bool == true
        if !projection {
            try container.encode(self.host, forKey: .host)
        }
        try container.encode(self.port, forKey: .port)
        if !projection {
            try container.encode(self.authMode, forKey: .authMode)
        }
        try container.encode(self.mode, forKey: .mode)
        try container.encode(self.bind, forKey: .bind)
        try container.encodeIfPresent(self.customBindHost, forKey: .customBindHost)
        try container.encodeIfPresent(self.publicOrigin, forKey: .publicOrigin)
        try container.encodeIfPresent(self.controlUi, forKey: .controlUi)
        try container.encode(self.auth, forKey: .auth)
        if !projection || !self.trustedProxies.isEmpty {
            try container.encode(self.trustedProxies, forKey: .trustedProxies)
        }
        if !projection || self.allowRealIpFallback {
            try container.encode(self.allowRealIpFallback, forKey: .allowRealIpFallback)
        }
        try container.encodeIfPresent(self.tailscale, forKey: .tailscale)
        try container.encodeIfPresent(self.remote, forKey: .remote)
        if let reload = self.reload {
            var reloadContainer = container.nestedContainer(keyedBy: ConfigCodingKey.self, forKey: .reload)
            try reloadContainer.encode(reload, forKey: ConfigCodingKey("mode"))
        }
        try container.encodeIfPresent(self.http, forKey: .http)
        try container.encodeIfPresent(self.push, forKey: .push)
        try container.encodeIfPresent(self.nodes, forKey: .nodes)
        if !projection {
            try container.encode(self.channelHealthCheckMinutes, forKey: .channelHealthCheckMinutes)
            try container.encodeIfPresent(self.handshakeTimeoutMs, forKey: .handshakeTimeoutMs)
        }
    }

    public var effectiveAuthMode: GatewayAuthMode {
        self.auth.mode
    }

    /// Connect handshake timeout: `OPENCLAW_HANDSHAKE_TIMEOUT_MS` wins over ``handshakeTimeoutMs``.
    /// - Parameter environment: Process environment.
    /// - Returns: Timeout in milliseconds, or `nil` for the transport default.
    public func effectiveHandshakeTimeoutMs(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        if let raw = environment[Self.handshakeTimeoutEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let value = Int(raw), value > 0
        {
            return value
        }
        return self.handshakeTimeoutMs
    }

    public func validationErrors() -> [String] {
        var errors = self.auth.validationErrors()
        if self.auth.mode == .trustedProxy && self.trustedProxies.isEmpty {
            errors.append("gateway.trustedProxies must contain at least one proxy IP when auth.mode is trusted-proxy.")
        }
        if self.bind == .custom {
            let customBindHost = self.customBindHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if customBindHost.isEmpty {
                errors.append("gateway.customBindHost is required when gateway.bind is custom.")
            }
        }
        if let publicOrigin, !Self.isValidPublicOrigin(publicOrigin) {
            errors.append(
                "gateway.publicOrigin must be a bare HTTPS origin; HTTP is allowed only for localhost, 127.0.0.1, or [::1]."
            )
        }
        if let edgeAuthError = self.remote?.edgeAuthValidationError() {
            errors.append(edgeAuthError)
        }
        return errors
    }

    /// Upstream `validateGatewayPublicOrigin`: an `http(s)` origin without path, query, fragment or
    /// credentials; plain HTTP only for loopback hosts.
    /// - Parameter value: Candidate origin.
    /// - Returns: `true` when valid.
    public static func isValidPublicOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }

    private static func deriveBind(from host: String) -> GatewayBindMode {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0.0.0.0", "::", "[::]":
            return .lan
        case "", "127.0.0.1", "::1", "localhost":
            return .loopback
        default:
            return .custom
        }
    }
}
