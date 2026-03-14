import Foundation
import Testing
@testable import OpenClawCore

@Suite("Gateway config")
struct GatewayConfigTests {
    @Test
    func gatewayConfigRoundTripsExpandedGatewaySurface() throws {
        let config = GatewayConfig(
            host: "0.0.0.0",
            port: 18_890,
            mode: .remote,
            bind: .lan,
            controlUi: GatewayControlUIConfig(
                enabled: true,
                basePath: "/openclaw",
                allowedOrigins: ["https://console.openclaw.ai"],
                allowInsecureAuth: false
            ),
            auth: GatewayAuthConfig(
                mode: .token,
                token: .ref(SecretRef(source: .env, id: "OPENCLAW_GATEWAY_TOKEN")),
                allowTailscale: true,
                rateLimit: GatewayAuthRateLimitConfig(maxAttempts: 5, windowMs: 30_000, lockoutMs: 120_000, exemptLoopback: true)
            ),
            tailscale: GatewayTailscaleConfig(mode: .serve, resetOnExit: true),
            remote: GatewayRemoteConfig(
                enabled: true,
                url: "wss://gateway.example.com/ws",
                transport: .direct,
                password: .ref(SecretRef(source: .file, id: "/gateway/password")),
                tlsFingerprint: "sha256:abc123"
            ),
            http: GatewayHTTPConfig(
                endpoints: GatewayHTTPEndpointsConfig(
                    chatCompletions: GatewayHTTPChatCompletionsConfig(
                        enabled: true,
                        maxBodyBytes: 2_048,
                        images: GatewayHTTPChatCompletionsImagesConfig(
                            allowURL: true,
                            urlAllowlist: ["cdn.example.com"],
                            allowedMIMEs: ["image/png"]
                        )
                    ),
                    responses: GatewayHTTPResponsesConfig(
                        enabled: true,
                        maxBodyBytes: 4_096,
                        files: GatewayHTTPResponsesFilesConfig(
                            allowURL: true,
                            pdf: GatewayHTTPResponsesPDFConfig(maxPages: 4, minTextChars: 120)
                        )
                    )
                ),
                securityHeaders: GatewayHTTPSecurityHeadersConfig(strictTransportSecurity: "max-age=31536000")
            ),
            push: GatewayPushConfig(
                apns: GatewayPushAPNsConfig(
                    relay: GatewayPushAPNsRelayConfig(baseURL: "https://relay.example.com", timeoutMs: 10_000)
                )
            ),
            trustedProxies: ["127.0.0.1"],
            allowRealIpFallback: true,
            channelHealthCheckMinutes: 9
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: encoded)

        #expect(decoded.host == "0.0.0.0")
        #expect(decoded.bind == GatewayBindMode.lan)
        #expect(decoded.mode == GatewayMode.remote)
        #expect(decoded.auth.mode == GatewayAuthMode.token)
        #expect(decoded.auth.token == SecretInput.ref(SecretRef(source: .env, provider: DEFAULT_SECRET_PROVIDER_ALIAS, id: "OPENCLAW_GATEWAY_TOKEN")))
        #expect(decoded.remote?.password == SecretInput.ref(SecretRef(source: .file, provider: DEFAULT_SECRET_PROVIDER_ALIAS, id: "/gateway/password")))
        #expect(decoded.http?.endpoints?.chatCompletions?.images?.allowURL == true)
        #expect(decoded.push?.apns?.relay?.baseURL == "https://relay.example.com")
        #expect(decoded.channelHealthCheckMinutes == 9)
    }

    @Test
    func gatewayConfigPrefersNestedAuthModeOverLegacyAuthModeDuringDecode() throws {
        let json = #"""
        {
          "host": "127.0.0.1",
          "authMode": "none",
          "auth": {
            "mode": "password",
            "password": "${OPENCLAW_GATEWAY_PASSWORD}"
          }
        }
        """#

        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: Data(json.utf8))

        #expect(decoded.authMode == GatewayAuthMode.password.rawValue)
        #expect(decoded.effectiveAuthMode == .password)
        #expect(decoded.auth.password == .ref(SecretRef(source: .env, provider: DEFAULT_SECRET_PROVIDER_ALIAS, id: "OPENCLAW_GATEWAY_PASSWORD")))
    }

    @Test
    func gatewayConfigValidationRequiresTrustedProxyFieldsAndCustomBindHost() {
        let config = GatewayConfig(
            bind: .custom,
            auth: GatewayAuthConfig(mode: .trustedProxy),
            trustedProxies: []
        )

        let errors = config.validationErrors()

        #expect(errors.contains("gateway.auth.trustedProxy.userHeader is required when auth.mode is trusted-proxy."))
        #expect(errors.contains("gateway.trustedProxies must contain at least one proxy IP when auth.mode is trusted-proxy."))
        #expect(errors.contains("gateway.customBindHost is required when gateway.bind is custom."))
    }

    @Test
    func securityAuditFlagsPlaintextGatewayCredentials() {
        let report = SecurityAuditRunner.run(
            options: SecurityAuditOptions(
                config: OpenClawConfig(
                    gateway: GatewayConfig(
                        auth: GatewayAuthConfig.plaintext(mode: .token, token: "gateway-token"),
                        remote: GatewayRemoteConfig.plaintext(token: "remote-token", password: "remote-password")
                    )
                )
            )
        )

        let detail = report.findings.first(where: { $0.id == "secrets.config.plaintext" })?.detail ?? ""

        #expect(detail.contains("gateway.auth.token"))
        #expect(detail.contains("gateway.remote.token"))
        #expect(detail.contains("gateway.remote.password"))
    }
}
