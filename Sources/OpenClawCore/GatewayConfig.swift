import Foundation

public enum GatewayMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case remote
}

public enum GatewayBindMode: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case lan
    case loopback
    case custom
    case tailnet
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

    public init(
        userHeader: String,
        requiredHeaders: [String]? = nil,
        allowUsers: [String]? = nil
    ) {
        self.userHeader = userHeader
        self.requiredHeaders = requiredHeaders
        self.allowUsers = allowUsers
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

    public init(
        mode: GatewayAuthMode = .token,
        token: SecretInput? = nil,
        password: SecretInput? = nil,
        allowTailscale: Bool? = nil,
        rateLimit: GatewayAuthRateLimitConfig? = nil,
        trustedProxy: GatewayTrustedProxyConfig? = nil
    ) {
        self.mode = mode
        self.token = token
        self.password = password
        self.allowTailscale = allowTailscale
        self.rateLimit = rateLimit
        self.trustedProxy = trustedProxy
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
        case rateLimit
        case trustedProxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(GatewayAuthMode.self, forKey: .mode) ?? .token
        self.token = try container.decodeIfPresent(SecretInput.self, forKey: .token)
        self.password = try container.decodeIfPresent(SecretInput.self, forKey: .password)
        self.allowTailscale = try container.decodeIfPresent(Bool.self, forKey: .allowTailscale)
        self.rateLimit = try container.decodeIfPresent(GatewayAuthRateLimitConfig.self, forKey: .rateLimit)
        self.trustedProxy = try container.decodeIfPresent(GatewayTrustedProxyConfig.self, forKey: .trustedProxy)
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        if self.mode == .trustedProxy {
            let userHeader = self.trustedProxy?.userHeader.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if userHeader.isEmpty {
                errors.append("gateway.auth.trustedProxy.userHeader is required when auth.mode is trusted-proxy.")
            }
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

    public init(
        mode: GatewayTailscaleMode? = nil,
        resetOnExit: Bool? = nil
    ) {
        self.mode = mode
        self.resetOnExit = resetOnExit
    }
}

public enum GatewayRemoteTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case ssh
    case direct
}

public struct GatewayRemoteConfig: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var url: String?
    public var transport: GatewayRemoteTransport?
    public var token: SecretInput?
    public var password: SecretInput?
    public var tlsFingerprint: String?
    public var sshTarget: String?
    public var sshIdentity: String?

    public init(
        enabled: Bool? = nil,
        url: String? = nil,
        transport: GatewayRemoteTransport? = nil,
        token: SecretInput? = nil,
        password: SecretInput? = nil,
        tlsFingerprint: String? = nil,
        sshTarget: String? = nil,
        sshIdentity: String? = nil
    ) {
        self.enabled = enabled
        self.url = url
        self.transport = transport
        self.token = token
        self.password = password
        self.tlsFingerprint = tlsFingerprint
        self.sshTarget = sshTarget
        self.sshIdentity = sshIdentity
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

public struct GatewayConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var authMode: String
    public var mode: GatewayMode
    public var bind: GatewayBindMode
    public var customBindHost: String?
    public var controlUi: GatewayControlUIConfig?
    public var auth: GatewayAuthConfig
    public var tailscale: GatewayTailscaleConfig?
    public var remote: GatewayRemoteConfig?
    public var http: GatewayHTTPConfig?
    public var push: GatewayPushConfig?
    public var trustedProxies: [String]
    public var allowRealIpFallback: Bool
    public var channelHealthCheckMinutes: Int

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
        channelHealthCheckMinutes: Int = 5
    ) {
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
        case controlUi
        case auth
        case tailscale
        case remote
        case http
        case push
        case trustedProxies
        case allowRealIpFallback
        case channelHealthCheckMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 18_789
        let mode = try container.decodeIfPresent(GatewayMode.self, forKey: .mode) ?? .local
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
            bind: try container.decodeIfPresent(GatewayBindMode.self, forKey: .bind),
            customBindHost: try container.decodeIfPresent(String.self, forKey: .customBindHost),
            controlUi: try container.decodeIfPresent(GatewayControlUIConfig.self, forKey: .controlUi),
            auth: normalizedAuth,
            tailscale: try container.decodeIfPresent(GatewayTailscaleConfig.self, forKey: .tailscale),
            remote: try container.decodeIfPresent(GatewayRemoteConfig.self, forKey: .remote),
            http: try container.decodeIfPresent(GatewayHTTPConfig.self, forKey: .http),
            push: try container.decodeIfPresent(GatewayPushConfig.self, forKey: .push),
            trustedProxies: try container.decodeIfPresent([String].self, forKey: .trustedProxies) ?? [],
            allowRealIpFallback: try container.decodeIfPresent(Bool.self, forKey: .allowRealIpFallback) ?? false,
            channelHealthCheckMinutes: try container.decodeIfPresent(Int.self, forKey: .channelHealthCheckMinutes) ?? 5
        )
    }

    public var effectiveAuthMode: GatewayAuthMode {
        self.auth.mode
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
        return errors
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
