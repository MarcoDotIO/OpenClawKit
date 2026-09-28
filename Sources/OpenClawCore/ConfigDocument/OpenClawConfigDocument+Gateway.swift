import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// Operator scope vocabulary (`src/gateway/operator-scopes.ts`).
    public struct OperatorScope: ConfigOpenEnum {
        /// Raw config string.
        public let rawValue: String
        /// Creates a value from its raw string.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Full administrative access.
        public static let admin = Self(rawValue: "operator.admin")
        /// Read access.
        public static let read = Self(rawValue: "operator.read")
        /// Write access.
        public static let write = Self(rawValue: "operator.write")
        /// Read sessions.
        public static let sessionsRead = Self(rawValue: "operator.sessions.read")
        /// Write sessions.
        public static let sessionsWrite = Self(rawValue: "operator.sessions.write")
        /// Resolve approvals.
        public static let approvals = Self(rawValue: "operator.approvals")
        /// Answer questions.
        public static let questions = Self(rawValue: "operator.questions")
        /// Pair devices and nodes.
        public static let pairing = Self(rawValue: "operator.pairing")
        /// Use Talk.
        public static let talk = Self(rawValue: "operator.talk")
        /// Read Talk provider secrets.
        public static let talkSecrets = Self(rawValue: "operator.talk.secrets")
        /// Known values.
        public static let known: [Self] = [
            .admin, .read, .write, .sessionsRead, .sessionsWrite, .approvals, .questions, .pairing, .talk, .talkSecrets,
        ]
    }

    /// `gateway`: listener, auth and control-plane settings (upstream `GatewayConfigSchema`).
    ///
    /// SDK-only keys of ``GatewayConfig`` (`host`, `authMode`, `remote.enabled`) and retired upstream
    /// keys never appear here; the migrator removes the retired ones from legacy files.
    public struct Gateway: ConfigDocumentObject {
        /// Default listener port.
        public static let defaultPort = 18_789

        /// Listener port (1...65535, default 18789).
        public var port: Int?
        /// `local` or `remote`.
        public var mode: Mode?
        /// Bind mode (default `loopback`).
        public var bind: Bind?
        /// Host for `bind = custom`.
        public var customBindHost: String?
        /// Bare HTTPS origin the gateway is reachable at (HTTP only for loopback hosts).
        public var publicOrigin: String?
        /// Portal ingress.
        public var portals: Portals?
        /// Control UI.
        public var controlUi: ControlUI?
        /// CLI agents.
        public var cliAgents: EnabledFlag?
        /// Web terminal.
        public var terminal: Terminal?
        /// Connection auth.
        public var auth: Auth?
        /// Operator roles.
        public var roles: Roles?
        /// Trusted reverse-proxy addresses.
        public var trustedProxies: [String]?
        /// Accept `X-Real-IP` when no forwarded chain is present.
        public var allowRealIpFallback: Bool?
        /// HTTP `/tools/invoke` policy.
        public var tools: ToolPolicy?
        /// Tailscale Serve/Funnel.
        public var tailscale: Tailscale?
        /// Remote gateway connection used by clients in `remote` mode.
        public var remote: Remote?
        /// Config reload.
        public var reload: Reload?
        /// TLS.
        public var tls: TLS?
        /// HTTP endpoints and headers.
        public var http: HTTP?
        /// Push relays.
        public var push: Push?
        /// Node pairing and commands.
        public var nodes: Nodes?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty gateway section.
        public init() {}

        /// Typed fields in upstream order.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("port", \.port), .init("mode", \.mode), .init("bind", \.bind), .init("customBindHost", \.customBindHost),
                .init("publicOrigin", \.publicOrigin), .init("portals", \.portals), .init("controlUi", \.controlUi),
                .init("cliAgents", \.cliAgents), .init("terminal", \.terminal), .init("auth", \.auth), .init("roles", \.roles),
                .init("trustedProxies", \.trustedProxies), .init("allowRealIpFallback", \.allowRealIpFallback),
                .init("tools", \.tools), .init("tailscale", \.tailscale), .init("remote", \.remote), .init("reload", \.reload),
                .init("tls", \.tls), .init("http", \.http), .init("push", \.push), .init("nodes", \.nodes),
            ]
        }

        /// The effective port (default 18789).
        public var effectivePort: Int {
            self.port ?? Self.defaultPort
        }

        /// `gateway.mode` vocabulary.
        public struct Mode: ConfigOpenEnum {
            /// Raw config string.
            public let rawValue: String
            /// Creates a value from its raw string.
            public init(rawValue: String) { self.rawValue = rawValue }
            /// Local gateway.
            public static let local = Self(rawValue: "local")
            /// Remote gateway.
            public static let remote = Self(rawValue: "remote")
            /// Known values.
            public static let known: [Self] = [.local, .remote]
        }

        /// `gateway.bind` vocabulary (host aliases are migrated to modes by the doctor port).
        public struct Bind: ConfigOpenEnum {
            /// Raw config string.
            public let rawValue: String
            /// Creates a value from its raw string.
            public init(rawValue: String) { self.rawValue = rawValue }
            /// Choose automatically.
            public static let auto = Self(rawValue: "auto")
            /// All LAN interfaces.
            public static let lan = Self(rawValue: "lan")
            /// Loopback only.
            public static let loopback = Self(rawValue: "loopback")
            /// `customBindHost`.
            public static let custom = Self(rawValue: "custom")
            /// Tailnet interface.
            public static let tailnet = Self(rawValue: "tailnet")
            /// Known values.
            public static let known: [Self] = [.auto, .lan, .loopback, .custom, .tailnet]
        }

        /// `{enabled}` toggle object.
        public struct EnabledFlag: ConfigDocumentObject {
            /// Enables the feature.
            public var enabled: Bool?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty toggle.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled)] }
        }

        /// `gateway.portals`.
        public struct Portals: ConfigDocumentObject {
            /// Portal ingress domain and port.
            public var ingress: Ingress?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("ingress", \.ingress)] }

            /// `gateway.portals.ingress`.
            public struct Ingress: ConfigDocumentObject {
                /// Bare DNS suffix for per-portal hostnames.
                public var domain: String?
                /// Ingress port (must differ from the gateway port).
                public var port: Int?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] { [.init("domain", \.domain), .init("port", \.port)] }
            }
        }

        /// `gateway.controlUi`.
        public struct ControlUI: ConfigDocumentObject {
            /// Retired bypass (upgrade input only; the migrator removes it).
            public var dangerouslyDisableDeviceAuth: Bool?
            /// Serve the Control UI.
            public var enabled: Bool?
            /// URL base path.
            public var basePath: String?
            /// Experimental features.
            public var experimental: Experimental?
            /// Custom UI root directory.
            public var root: String?
            /// Environment banner.
            public var environment: Environment?
            /// Show the community invite.
            public var communityInvite: Bool?
            /// GitHub token used by the UI.
            public var github: GitHub?
            /// Session observer view.
            public var sessionObserver: Bool?
            /// Embed sandbox policy: `strict`, `scripts` or `trusted`.
            public var embedSandbox: String?
            /// Allow embedding external URLs.
            public var allowExternalEmbedUrls: Bool?
            /// Fetch favicons automatically.
            public var automaticallyFetchFavicons: Bool?
            /// Allowed browser origins.
            public var allowedOrigins: [String]?
            /// Fall back to the Host header for origin checks.
            public var dangerouslyAllowHostHeaderOriginFallback: Bool?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates an empty value.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("dangerouslyDisableDeviceAuth", \.dangerouslyDisableDeviceAuth), .init("enabled", \.enabled),
                    .init("basePath", \.basePath), .init("experimental", \.experimental), .init("root", \.root),
                    .init("environment", \.environment), .init("communityInvite", \.communityInvite), .init("github", \.github),
                    .init("sessionObserver", \.sessionObserver), .init("embedSandbox", \.embedSandbox),
                    .init("allowExternalEmbedUrls", \.allowExternalEmbedUrls),
                    .init("automaticallyFetchFavicons", \.automaticallyFetchFavicons), .init("allowedOrigins", \.allowedOrigins),
                    .init("dangerouslyAllowHostHeaderOriginFallback", \.dangerouslyAllowHostHeaderOriginFallback),
                ]
            }

            /// `controlUi.experimental`.
            public struct Experimental: ConfigDocumentObject {
                /// Allow custom UI plugins.
                public var customPlugins: Bool?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] { [.init("customPlugins", \.customPlugins)] }
            }

            /// `controlUi.environment` banner.
            public struct Environment: ConfigDocumentObject {
                /// Label (1...24 characters).
                public var label: String?
                /// `teal`, `amber`, `purple`, `coral`, `pink`, `blue`, `green`, `red` or `gray`.
                public var color: String?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] { [.init("label", \.label), .init("color", \.color)] }
            }

            /// `controlUi.github`.
            public struct GitHub: ConfigDocumentObject {
                /// GitHub token (secret).
                public var token: ConfigSecretValue?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] { [.init("token", \.token)] }
            }
        }

        /// `gateway.terminal`.
        public struct Terminal: ConfigDocumentObject {
            /// Enables the terminal (default `true`).
            public var enabled: Bool?
            /// Shell executable.
            public var shell: String?
            /// Detached session timeout in seconds (default 300).
            public var detachedSessionTimeoutSeconds: Int?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("shell", \.shell), .init("detachedSessionTimeoutSeconds", \.detachedSessionTimeoutSeconds)]
            }
        }

        /// `gateway.auth`.
        public struct Auth: ConfigDocumentObject {
            /// `none`, `token`, `password` or `trusted-proxy`.
            public var mode: String?
            /// Shared token (secret).
            public var token: ConfigSecretValue?
            /// Shared password (secret).
            public var password: ConfigSecretValue?
            /// Accept Tailscale identity headers.
            public var allowTailscale: Bool?
            /// Scopes granted per trusted identity.
            public var identityScopes: [String: [OperatorScope]]?
            /// Failed-auth rate limit.
            public var rateLimit: RateLimit?
            /// Trusted reverse-proxy identity.
            public var trustedProxy: TrustedProxy?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]

            /// Creates an empty value.
            public init() {}

            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("mode", \.mode), .init("token", \.token), .init("password", \.password),
                    .init("allowTailscale", \.allowTailscale), .init("identityScopes", \.identityScopes),
                    .init("rateLimit", \.rateLimit), .init("trustedProxy", \.trustedProxy),
                ]
            }

            /// The configured shared secret: the token in token mode, the password in password mode,
            /// otherwise whichever is set (upstream accepts the secret in either field).
            public var sharedSecret: ConfigSecretValue? {
                switch self.mode {
                case "password":
                    return self.password ?? self.token
                default:
                    return self.token ?? self.password
                }
            }

            /// `gateway.auth.rateLimit` (defaults: 10 attempts, 60000 ms window, 300000 ms lockout, loopback exempt).
            public struct RateLimit: ConfigDocumentObject {
                /// Default maximum attempts per window.
                public static let defaultMaxAttempts = 10
                /// Default window in milliseconds.
                public static let defaultWindowMs = 60_000
                /// Default lockout in milliseconds.
                public static let defaultLockoutMs = 300_000

                /// Attempts per window.
                public var maxAttempts: Int?
                /// Window length in milliseconds.
                public var windowMs: Int?
                /// Lockout in milliseconds.
                public var lockoutMs: Int?
                /// Exempt loopback clients (default `true`).
                public var exemptLoopback: Bool?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] {
                    [.init("maxAttempts", \.maxAttempts), .init("windowMs", \.windowMs), .init("lockoutMs", \.lockoutMs),
                     .init("exemptLoopback", \.exemptLoopback)]
                }
            }

            /// `gateway.auth.trustedProxy`.
            public struct TrustedProxy: ConfigDocumentObject {
                /// Header carrying the authenticated user (required).
                public var userHeader: String?
                /// Headers that must be present.
                public var requiredHeaders: [String]?
                /// Allowed users.
                public var allowUsers: [String]?
                /// Accept proxied requests from loopback.
                public var allowLoopback: Bool?
                /// Cloudflare Access OIDC verification.
                public var cloudflareAccessOidc: CloudflareAccessOIDC?
                /// Automatic device approval for proxied identities.
                public var deviceAutoApprove: DeviceAutoApprove?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] {
                    [
                        .init("userHeader", \.userHeader), .init("requiredHeaders", \.requiredHeaders),
                        .init("allowUsers", \.allowUsers), .init("allowLoopback", \.allowLoopback),
                        .init("cloudflareAccessOidc", \.cloudflareAccessOidc), .init("deviceAutoApprove", \.deviceAutoApprove),
                    ]
                }

                /// Cloudflare Access issuer settings.
                public struct CloudflareAccessOIDC: ConfigDocumentObject {
                    /// `https://<team>.cloudflareaccess.com`.
                    public var issuer: String?
                    /// Identity provider id.
                    public var providerId: String?
                    /// Claim holding the GitHub account id.
                    public var githubAccountIdClaim: String?
                    /// Passthrough keys.
                    public var additionalProperties: [String: AnyCodable] = [:]
                    /// Creates an empty value.
                    public init() {}
                    /// Typed fields.
                    public static var configFields: [ConfigField<Self>] {
                        [.init("issuer", \.issuer), .init("providerId", \.providerId), .init("githubAccountIdClaim", \.githubAccountIdClaim)]
                    }
                }

                /// Device auto-approval.
                public struct DeviceAutoApprove: ConfigDocumentObject {
                    /// Enables auto-approval (default `false`).
                    public var enabled: Bool?
                    /// Scopes granted to auto-approved devices.
                    public var scopes: [String]?
                    /// Passthrough keys.
                    public var additionalProperties: [String: AnyCodable] = [:]
                    /// Creates an empty value.
                    public init() {}
                    /// Typed fields.
                    public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled), .init("scopes", \.scopes)] }
                }
            }
        }

        /// `gateway.roles`.
        public struct Roles: ConfigDocumentObject {
            /// Default role name (must name a definition).
            public var `default`: String?
            /// Role definitions by name.
            public var definitions: [String: RoleDefinition]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("default", \.default), .init("definitions", \.definitions)] }

            /// One operator role.
            public struct RoleDefinition: ConfigDocumentObject {
                /// Access to other operators' sessions.
                public var sessions: Sessions?
                /// `inherit` or `required`.
                public var sandbox: String?
                /// Allowed agents as authored: `"*"` or an array of agent ids.
                public var agents: AnyCodable?
                /// Granted operator scopes.
                public var scopes: [OperatorScope]?
                /// Access-policy plugin id.
                public var accessPolicyPlugin: String?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] {
                    [
                        .init("sessions", \.sessions), .init("sandbox", \.sandbox), .init("agents", \.agents),
                        .init("scopes", \.scopes), .init("accessPolicyPlugin", \.accessPolicyPlugin),
                    ]
                }

                /// Whether the role allows every agent (`agents: "*"`).
                public var allowsAllAgents: Bool {
                    self.agents?.stringValue == "*"
                }

                /// Explicit agent ids, when `agents` is a list.
                public var agentIDs: [String]? {
                    self.agents?.arrayValue?.compactMap(\.stringValue)
                }

                /// `sessions` access.
                public struct Sessions: ConfigDocumentObject {
                    /// `none`, `view`, `suggest` or `write`.
                    public var others: String?
                    /// Passthrough keys.
                    public var additionalProperties: [String: AnyCodable] = [:]
                    /// Creates an empty value.
                    public init() {}
                    /// Typed fields.
                    public static var configFields: [ConfigField<Self>] { [.init("others", \.others)] }
                }
            }
        }

        /// Allow/deny tool policy (`gateway.tools`).
        public struct ToolPolicy: ConfigDocumentObject {
            /// Denied tools.
            public var deny: [String]?
            /// Allowed tools.
            public var allow: [String]?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("deny", \.deny), .init("allow", \.allow)] }
        }

        /// `gateway.tailscale`.
        public struct Tailscale: ConfigDocumentObject {
            /// `off`, `serve` or `funnel`.
            public var mode: String?
            /// Keep Funnel routes (deprecated).
            public var preserveFunnel: Bool?
            /// Passthrough keys (the retired `resetOnExit`/`serviceName` until migrated).
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("mode", \.mode), .init("preserveFunnel", \.preserveFunnel)] }
        }

        /// `gateway.remote`.
        public struct Remote: ConfigDocumentObject {
            /// Remote gateway URL.
            public var url: String?
            /// `ssh` or `direct`.
            public var transport: String?
            /// Remote gateway port for SSH tunnels.
            public var remotePort: Int?
            /// Token (secret).
            public var token: ConfigSecretValue?
            /// Password (secret).
            public var password: ConfigSecretValue?
            /// Extra auth headers for edge proxies (values are secrets).
            public var edgeAuth: [String: ConfigSecretValue]?
            /// Explicit TLS certificate fingerprint pin.
            public var tlsFingerprint: String?
            /// SSH target (`user@host`).
            public var sshTarget: String?
            /// SSH identity file.
            public var sshIdentity: String?
            /// `strict` or `openssh`.
            public var sshHostKeyPolicy: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("url", \.url), .init("transport", \.transport), .init("remotePort", \.remotePort), .init("token", \.token),
                    .init("password", \.password), .init("edgeAuth", \.edgeAuth), .init("tlsFingerprint", \.tlsFingerprint),
                    .init("sshTarget", \.sshTarget), .init("sshIdentity", \.sshIdentity), .init("sshHostKeyPolicy", \.sshHostKeyPolicy),
                ]
            }
        }

        /// `gateway.reload`.
        public struct Reload: ConfigDocumentObject {
            /// `off` or `hybrid`.
            public var mode: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("mode", \.mode)] }
        }

        /// `gateway.tls`.
        public struct TLS: ConfigDocumentObject {
            /// Enables TLS.
            public var enabled: Bool?
            /// Generate a self-signed certificate.
            public var autoGenerate: Bool?
            /// Certificate path.
            public var certPath: String?
            /// Private key path.
            public var keyPath: String?
            /// CA bundle path.
            public var caPath: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("enabled", \.enabled), .init("autoGenerate", \.autoGenerate), .init("certPath", \.certPath),
                 .init("keyPath", \.keyPath), .init("caPath", \.caPath)]
            }
        }

        /// `gateway.http`.
        public struct HTTP: ConfigDocumentObject {
            /// OpenAI-compatible endpoints (typed shallowly; nested limits pass through).
            public var endpoints: AnyCodable?
            /// Security headers.
            public var securityHeaders: SecurityHeaders?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("endpoints", \.endpoints), .init("securityHeaders", \.securityHeaders)] }

            /// `gateway.http.securityHeaders`.
            public struct SecurityHeaders: ConfigDocumentObject {
                /// `Strict-Transport-Security` value, or `false` to disable it.
                public var strictTransportSecurity: ConfigStringOrFalse?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] { [.init("strictTransportSecurity", \.strictTransportSecurity)] }
            }
        }

        /// `gateway.push`.
        public struct Push: ConfigDocumentObject {
            /// APNs relay (typed shallowly).
            public var apns: AnyCodable?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] { [.init("apns", \.apns)] }
        }

        /// `gateway.nodes`.
        public struct Nodes: ConfigDocumentObject {
            /// Browser node selection.
            public var browser: Browser?
            /// Node pairing.
            public var pairing: Pairing?
            /// Plugin tools on nodes.
            public var pluginTools: EnabledFlag?
            /// Allow skills on nodes (default `true`).
            public var allowSkills: Bool?
            /// Node command allow/deny lists.
            public var commands: ToolPolicy?
            /// Passthrough keys (the retired `allowCommands`/`denyCommands` until migrated).
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty value.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [.init("browser", \.browser), .init("pairing", \.pairing), .init("pluginTools", \.pluginTools),
                 .init("allowSkills", \.allowSkills), .init("commands", \.commands)]
            }

            /// `gateway.nodes.browser`.
            public struct Browser: ConfigDocumentObject {
                /// `auto`, `manual` or `off`.
                public var mode: String?
                /// Node id.
                public var node: String?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] { [.init("mode", \.mode), .init("node", \.node)] }
            }

            /// `gateway.nodes.pairing`.
            public struct Pairing: ConfigDocumentObject {
                /// Auto-approve local nodes (default `true`).
                public var autoApproveLocal: Bool?
                /// CIDRs auto-approved.
                public var autoApproveCidrs: [String]?
                /// SSH verification: `true`/`false` or detailed settings.
                public var sshVerify: ConfigFlagOr<SSHVerify>?
                /// Passthrough keys.
                public var additionalProperties: [String: AnyCodable] = [:]
                /// Creates an empty value.
                public init() {}
                /// Typed fields.
                public static var configFields: [ConfigField<Self>] {
                    [.init("autoApproveLocal", \.autoApproveLocal), .init("autoApproveCidrs", \.autoApproveCidrs),
                     .init("sshVerify", \.sshVerify)]
                }

                /// Detailed SSH verification settings.
                public struct SSHVerify: ConfigDocumentObject {
                    /// SSH user.
                    public var user: String?
                    /// SSH identity file.
                    public var identity: String?
                    /// Timeout in milliseconds (default 7000).
                    public var timeoutMs: Int?
                    /// CIDRs verified over SSH.
                    public var cidrs: [String]?
                    /// Passthrough keys.
                    public var additionalProperties: [String: AnyCodable] = [:]
                    /// Creates an empty value.
                    public init() {}
                    /// Typed fields.
                    public static var configFields: [ConfigField<Self>] {
                        [.init("user", \.user), .init("identity", \.identity), .init("timeoutMs", \.timeoutMs), .init("cidrs", \.cidrs)]
                    }
                }
            }
        }
    }
}
