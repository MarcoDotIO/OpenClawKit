import Foundation

/// Severity level for one security audit finding.
public enum SecurityAuditSeverity: String, Codable, Sendable, Equatable {
    case info
    case warning
    case error
}

/// One actionable security finding.
public struct SecurityAuditFinding: Codable, Sendable, Equatable {
    /// Stable finding identifier.
    public let id: String
    /// Finding severity.
    public let severity: SecurityAuditSeverity
    /// Human-readable summary.
    public let summary: String
    /// Additional detail for operators.
    public let detail: String
    /// Optional file path tied to this finding.
    public let filePath: String?
    /// Optional remediation guidance.
    public let recommendation: String?

    /// Creates a security finding.
    public init(
        id: String,
        severity: SecurityAuditSeverity,
        summary: String,
        detail: String,
        filePath: String? = nil,
        recommendation: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.detail = detail
        self.filePath = filePath
        self.recommendation = recommendation
    }
}

/// An accepted audit finding (upstream `security.audit.suppressions[]`).
///
/// A finding matches when its id equals ``checkID`` exactly and every present substring condition
/// matches case-insensitively (``titleIncludes`` against the summary, ``detailIncludes`` against the detail).
public struct SecurityAuditSuppression: Codable, Sendable, Equatable {
    /// Finding id to suppress (exact match).
    public var checkID: String
    /// Case-insensitive substring the finding summary must contain.
    public var titleIncludes: String?
    /// Case-insensitive substring the finding detail must contain.
    public var detailIncludes: String?
    /// Why the finding is accepted.
    public var reason: String?

    /// Creates a suppression.
    /// - Parameters:
    ///   - checkID: Finding id.
    ///   - titleIncludes: Summary substring condition.
    ///   - detailIncludes: Detail substring condition.
    ///   - reason: Acceptance reason.
    public init(checkID: String, titleIncludes: String? = nil, detailIncludes: String? = nil, reason: String? = nil) {
        self.checkID = checkID
        self.titleIncludes = titleIncludes
        self.detailIncludes = detailIncludes
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case checkID = "checkId"
        case titleIncludes
        case detailIncludes
        case reason
    }

    /// Whether this suppression accepts `finding`.
    /// - Parameter finding: Audit finding.
    /// - Returns: `true` when every present condition matches.
    public func matches(_ finding: SecurityAuditFinding) -> Bool {
        guard finding.id == self.checkID else {
            return false
        }
        if let title = self.titleIncludes?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           finding.summary.range(of: title, options: .caseInsensitive) == nil
        {
            return false
        }
        if let detail = self.detailIncludes?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty,
           finding.detail.range(of: detail, options: .caseInsensitive) == nil
        {
            return false
        }
        return true
    }
}

/// Security audit output report.
public struct SecurityAuditReport: Codable, Sendable, Equatable {
    /// Report generation timestamp.
    public let generatedAt: Date
    /// Ordered findings emitted by the auditor.
    public let findings: [SecurityAuditFinding]
    /// Optional replay-ledger integrity verification details.
    public let replayLedgerIntegrity: ReplayLedgerVerificationResult?
    /// Findings accepted by ``SecurityAuditOptions/suppressions`` (omitted from ``findings`` and the summary).
    public let suppressedFindings: [SecurityAuditFinding]

    /// Creates a security audit report.
    public init(
        generatedAt: Date = Date(),
        findings: [SecurityAuditFinding],
        replayLedgerIntegrity: ReplayLedgerVerificationResult? = nil,
        suppressedFindings: [SecurityAuditFinding] = []
    ) {
        self.generatedAt = generatedAt
        self.findings = findings
        self.replayLedgerIntegrity = replayLedgerIntegrity
        self.suppressedFindings = suppressedFindings
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case findings
        case replayLedgerIntegrity
        case suppressedFindings
    }

    /// Decodes a report; `suppressedFindings` defaults to empty for reports written before 2026.3.0.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.findings = try container.decode([SecurityAuditFinding].self, forKey: .findings)
        self.replayLedgerIntegrity = try container.decodeIfPresent(ReplayLedgerVerificationResult.self, forKey: .replayLedgerIntegrity)
        self.suppressedFindings = try container.decodeIfPresent([SecurityAuditFinding].self, forKey: .suppressedFindings) ?? []
    }

    /// Returns number of findings for a specific severity.
    public func count(for severity: SecurityAuditSeverity) -> Int {
        self.findings.filter { $0.severity == severity }.count
    }

    /// Returns highest finding severity in the report.
    public var highestSeverity: SecurityAuditSeverity {
        if self.findings.contains(where: { $0.severity == .error }) {
            return .error
        }
        if self.findings.contains(where: { $0.severity == .warning }) {
            return .warning
        }
        return .info
    }

    /// Returns whether report includes error-level findings.
    public var hasBlockingFindings: Bool {
        self.findings.contains(where: { $0.severity == .error })
    }
}

/// Input options for running the security audit.
public struct SecurityAuditOptions: Sendable, Equatable {
    /// Optional config object used for risky-default and plaintext-secret checks.
    public let config: OpenClawConfig?
    /// Optional config file path checked for file permissions and plaintext keys.
    public let configFileURL: URL?
    /// Additional state/config paths checked for restrictive permissions.
    public let statePaths: [URL]
    /// Extra files scanned for plaintext secret key patterns.
    public let plaintextSecretFiles: [URL]
    /// Optional replay-ledger envelopes for integrity auditing.
    public let replayLedgerEnvelopes: [ReplayEventEnvelope]
    /// Requires detached signature verification for all replay-ledger events.
    public let requireReplayLedgerSignatureVerification: Bool
    /// Upstream `openclaw.json` document scanned for plaintext secrets on upstream-only paths.
    public let document: OpenClawConfigDocument?
    /// Accepted findings; matches move to ``SecurityAuditReport/suppressedFindings``. When empty, the
    /// document's `security.audit.suppressions` are used.
    public let suppressions: [SecurityAuditSuppression]

    /// Creates security audit options.
    public init(
        config: OpenClawConfig? = nil,
        configFileURL: URL? = nil,
        statePaths: [URL] = [],
        plaintextSecretFiles: [URL] = [],
        replayLedgerEnvelopes: [ReplayEventEnvelope] = [],
        requireReplayLedgerSignatureVerification: Bool = false,
        document: OpenClawConfigDocument? = nil,
        suppressions: [SecurityAuditSuppression] = []
    ) {
        self.config = config
        self.configFileURL = configFileURL
        self.statePaths = statePaths
        self.plaintextSecretFiles = plaintextSecretFiles
        self.replayLedgerEnvelopes = replayLedgerEnvelopes
        self.requireReplayLedgerSignatureVerification = requireReplayLedgerSignatureVerification
        self.document = document
        self.suppressions = suppressions
    }

    /// Suppressions in effect: explicit ones, else the document's `security.audit.suppressions`.
    public var effectiveSuppressions: [SecurityAuditSuppression] {
        if !self.suppressions.isEmpty {
            return self.suppressions
        }
        return self.document?.security?.auditSuppressions ?? []
    }
}

/// Lightweight security audit runner for host applications.
public enum SecurityAuditRunner {
    /// Runs a security audit pass and returns the generated report.
    /// - Parameters:
    ///   - options: Audit options.
    ///   - replayLedgerSigner: Optional signer used for signature verification.
    /// - Returns: Structured audit report.
    public static func run(
        options: SecurityAuditOptions = SecurityAuditOptions(),
        replayLedgerSigner: (any ReplayLedgerSigner)? = nil
    ) -> SecurityAuditReport {
        var findings: [SecurityAuditFinding] = []
        var replayLedgerIntegrity: ReplayLedgerVerificationResult?

        if let config = options.config {
            findings.append(contentsOf: self.checkConfigSecrets(config))
            findings.append(contentsOf: self.checkRiskyDefaults(config))
            findings.append(contentsOf: self.checkGatewaySharedSecret(config.gateway.auth))
            // Channel-owned findings: plaintext channel secrets (upstream path spelling, plugin
            // sections and `accounts.*`), BlueBubbles removal and Teams sovereign clouds.
            findings.append(contentsOf: config.channels.securityAuditFindings())
        }
        if let document = options.document {
            findings.append(contentsOf: self.checkDocumentSecrets(document))
            if options.config == nil, let channels = document.channels {
                // Without an SDK-native config, audit the document's channel blocks directly.
                findings.append(contentsOf: channels.channelsConfig.securityAuditFindings())
            }
        }

        var permissionPaths = options.statePaths
        if let configFileURL = options.configFileURL {
            permissionPaths.append(configFileURL)
        }
        findings.append(contentsOf: self.checkPathPermissions(permissionPaths))

        var plaintextFiles = options.plaintextSecretFiles
        if let configFileURL = options.configFileURL {
            plaintextFiles.append(configFileURL)
        }
        findings.append(contentsOf: self.checkPlaintextSecretFiles(plaintextFiles))

        if !options.replayLedgerEnvelopes.isEmpty {
            let integrity = self.checkReplayLedgerIntegrity(
                options.replayLedgerEnvelopes,
                signer: replayLedgerSigner,
                requireSignatures: options.requireReplayLedgerSignatureVerification
            )
            replayLedgerIntegrity = integrity.result
            findings.append(contentsOf: integrity.findings)
        }

        let ordered = findings.sorted { lhs, rhs in
            let lhsRank = self.severityRank(lhs.severity)
            let rhsRank = self.severityRank(rhs.severity)
            if lhsRank == rhsRank {
                return lhs.id < rhs.id
            }
            return lhsRank > rhsRank
        }
        let suppressions = options.effectiveSuppressions
        let suppressed = ordered.filter { finding in suppressions.contains { $0.matches(finding) } }
        let active = ordered.filter { finding in !suppressions.contains { $0.matches(finding) } }
        return SecurityAuditReport(
            findings: active,
            replayLedgerIntegrity: replayLedgerIntegrity,
            suppressedFindings: suppressed
        )
    }

    /// Plaintext secrets on upstream-only document paths (Control UI GitHub token, remote edge auth,
    /// provider request auth and headers, skill/Talk/TTS/memory API keys, cron webhook token, hooks token).
    private static func checkDocumentSecrets(_ document: OpenClawConfigDocument) -> [SecurityAuditFinding] {
        var exposed: [String] = []
        func check(_ path: String, _ value: ConfigSecretValue?) {
            guard let plaintext = value?.plaintext?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !plaintext.isEmpty, value?.isRedacted != true
            else { return }
            exposed.append(path)
        }
        let gateway = document.gateway
        check("gateway.auth.token", gateway?.auth?.token)
        check("gateway.auth.password", gateway?.auth?.password)
        check("gateway.controlUi.github.token", gateway?.controlUi?.github?.token)
        check("gateway.remote.token", gateway?.remote?.token)
        check("gateway.remote.password", gateway?.remote?.password)
        for (header, value) in gateway?.remote?.edgeAuth ?? [:] {
            check("gateway.remote.edgeAuth.\(header)", value)
        }
        for (providerID, provider) in document.models?.providers ?? [:] {
            if !ModelAuthMarkers.isNonSecretMarker(provider.apiKey?.plaintext) {
                check("models.providers.\(providerID).apiKey", provider.apiKey)
            }
            for (header, value) in provider.headers ?? [:] {
                check("models.providers.\(providerID).headers.\(header)", value)
            }
            if let auth = provider.request?.dictionaryValue?["auth"]?.dictionaryValue {
                for key in ["token", "value"] {
                    if let raw = auth[key], let string = raw.stringValue {
                        check("models.providers.\(providerID).request.auth.\(key)", ConfigSecretValue(string: string))
                    }
                }
            }
        }
        for (skillID, entry) in document.skills?.entries ?? [:] {
            check("skills.entries.\(skillID).apiKey", entry.apiKey)
        }
        for (providerID, entry) in document.talk?.providers ?? [:] {
            check("talk.providers.\(providerID).apiKey", entry.apiKey)
        }
        for (providerID, entry) in document.tts?.providers ?? [:] {
            check("tts.providers.\(providerID).apiKey", entry.apiKey)
        }
        check("memory.search.remote.apiKey", document.memory?.search?.remote?.apiKey)
        check("cron.webhookToken", document.cron?.webhookToken)
        if let token = document.hooks?.token {
            check("hooks.token", ConfigSecretValue(string: token))
        }
        guard !exposed.isEmpty else {
            return []
        }
        return [
            SecurityAuditFinding(
                id: "secrets.document.plaintext",
                severity: .warning,
                summary: "openclaw.json includes plaintext secrets",
                detail: "Found non-empty plaintext secret values at: \(exposed.sorted().joined(separator: ", "))",
                recommendation: "Replace plaintext values with SecretRefs ({source, provider, id}) or ${ENV_VAR} references."
            ),
        ]
    }

    /// Placeholder and weak-secret checks for the gateway shared secret.
    private static func checkGatewaySharedSecret(_ auth: GatewayAuthConfig) -> [SecurityAuditFinding] {
        guard auth.mode == .token || auth.mode == .password, let secret = auth.sharedSecret?.stringValue else {
            return []
        }
        switch GatewaySharedSecretPolicy.evaluate(secret) {
        case .placeholder:
            return [
                SecurityAuditFinding(
                    id: "gateway.auth.secret-placeholder",
                    severity: .error,
                    summary: "Gateway shared secret is a placeholder",
                    detail: "gateway.auth uses a blank or well-known placeholder secret.",
                    recommendation: "Generate a random secret (for example `openssl rand -hex 32`) or use a SecretRef."
                ),
            ]
        case .weak:
            return [
                SecurityAuditFinding(
                    id: "gateway.auth.secret-weak",
                    severity: .warning,
                    summary: "Gateway shared secret is short",
                    detail: "gateway.auth secret is shorter than \(GatewaySharedSecretPolicy.minimumRecommendedLength) characters.",
                    recommendation: "Use a random secret of at least \(GatewaySharedSecretPolicy.minimumRecommendedLength) characters."
                ),
            ]
        case .acceptable:
            return []
        }
    }

    /// Plaintext secrets in SDK-native config keys.
    ///
    /// Typed channel sections are reported by ``ChannelsConfig/securityAuditFindings()`` under
    /// `channels.secrets.plaintext` (upstream path spelling), so only the SDK-only legacy
    /// `channels.pluginChannels.*.secrets` wrapper is listed here. Non-secret provider markers
    /// (``ModelAuthMarkers``, for example `apple-fm-local`) are never reported.
    private static func checkConfigSecrets(_ config: OpenClawConfig) -> [SecurityAuditFinding] {
        var exposedKeys: [String] = []

        let secrets: [(String, String?)] = [
            ("gateway.auth.token", config.gateway.auth.token?.stringValue),
            ("gateway.auth.password", config.gateway.auth.password?.stringValue),
            ("gateway.remote.token", config.gateway.remote?.token?.stringValue),
            ("gateway.remote.password", config.gateway.remote?.password?.stringValue),
            ("models.openAI.apiKey", config.models.openAI.apiKey),
            ("models.openAICompatible.apiKey", config.models.openAICompatible.apiKey),
            ("models.anthropic.apiKey", config.models.anthropic.apiKey),
            ("models.gemini.apiKey", config.models.gemini.apiKey),
        ]
        for (key, value) in secrets {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
               !(key.hasPrefix("models.") && ModelAuthMarkers.isNonSecretMarker(trimmed))
            {
                exposedKeys.append(key)
            }
        }
        for (providerID, provider) in config.models.providers {
            let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else {
                continue
            }
            if let secret = provider.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty,
               !ModelAuthMarkers.isNonSecretMarker(secret)
            {
                exposedKeys.append("models.providers.\(normalizedID).apiKey")
            }
        }
        for (channelID, channelConfig) in config.channels.pluginChannels {
            let normalizedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else {
                continue
            }
            for (secretKey, secretValue) in channelConfig.secrets {
                let normalizedSecretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedSecretValue = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedSecretKey.isEmpty, !normalizedSecretValue.isEmpty {
                    exposedKeys.append("channels.pluginChannels.\(normalizedID).secrets.\(normalizedSecretKey)")
                }
            }
        }

        guard !exposedKeys.isEmpty else {
            return []
        }
        return [
            SecurityAuditFinding(
                id: "secrets.config.plaintext",
                severity: .warning,
                summary: "Configuration includes plaintext secrets",
                detail: "Found non-empty secret values in config keys: \(exposedKeys.sorted().joined(separator: ", "))",
                recommendation:
                    "Move sensitive values to CredentialStore/Keychain-backed storage or auth-profile storage and avoid committing plaintext values."
            ),
        ]
    }

    private static func checkRiskyDefaults(_ config: OpenClawConfig) -> [SecurityAuditFinding] {
        var findings: [SecurityAuditFinding] = []

        if !config.routing.includeChannelID, !config.routing.includeAccountID, !config.routing.includePeerID {
            findings.append(
                SecurityAuditFinding(
                    id: "routing.shared-session",
                    severity: .warning,
                    summary: "Routing collapses all traffic into one shared session key",
                    detail: "Session routing disables channel/account/peer dimensions and may leak context across unrelated conversations.",
                    recommendation: "Enable at least one routing discriminator (`includeChannelID`, `includeAccountID`, or `includePeerID`)."
                )
            )
        }

        if config.channels.discord.enabled, !config.channels.discord.mentionOnly {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.discord.mention-only-disabled",
                    severity: .warning,
                    summary: "Discord adapter processes all channel messages",
                    detail: "Discord `mentionOnly` is disabled while adapter is enabled.",
                    recommendation: "Enable `mentionOnly` unless broad-channel auto-replies are explicitly required."
                )
            )
        }

        if config.channels.telegram.enabled, !config.channels.telegram.mentionOnly {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.telegram.mention-only-disabled",
                    severity: .warning,
                    summary: "Telegram adapter processes all group messages",
                    detail: "Telegram `mentionOnly` is disabled while adapter is enabled.",
                    recommendation: "Enable `mentionOnly` unless broad-group auto-replies are explicitly required."
                )
            )
        }
        if config.channels.slack.enabled, !config.channels.slack.mentionOnly {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.slack.mention-only-disabled",
                    severity: .warning,
                    summary: "Slack adapter processes all channel messages",
                    detail: "Slack `mentionOnly` is disabled while adapter is enabled.",
                    recommendation: "Enable `mentionOnly` unless broad-channel auto-replies are explicitly required."
                )
            )
        }
        if config.channels.msteams.enabled, !config.channels.msteams.mentionOnly {
            findings.append(
                SecurityAuditFinding(
                    id: "channels.msteams.mention-only-disabled",
                    severity: .warning,
                    summary: "Microsoft Teams adapter processes all conversation messages",
                    detail: "Microsoft Teams `mentionOnly` is disabled while adapter is enabled.",
                    recommendation: "Enable `mentionOnly` unless broad-channel auto-replies are explicitly required."
                )
            )
        }
        if config.channels.googleChat.enabled {
            let verificationToken = config.channels.googleChat.verificationToken?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if verificationToken.isEmpty {
                findings.append(
                    SecurityAuditFinding(
                        id: "channels.googlechat.verification-token-missing",
                        severity: .warning,
                        summary: "Google Chat webhook verification token is missing",
                        detail: "Google Chat adapter is enabled without a verification token.",
                        recommendation: "Set `channels.googlechat.verificationToken` to validate inbound webhook authenticity."
                    )
                )
            }
        }
        if config.channels.webchat.enabled {
            let sharedSecret = config.channels.webchat.sharedSecret?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if sharedSecret.isEmpty {
                findings.append(
                    SecurityAuditFinding(
                        id: "channels.webchat.shared-secret-missing",
                        severity: .warning,
                        summary: "WebChat shared secret is missing",
                        detail: "WebChat adapter is enabled without a shared secret.",
                        recommendation: "Set `channels.webchat.sharedSecret` to prevent unauthorized webhook submissions."
                    )
                )
            }
        }
        if config.channels.signal.enabled {
            let signalURL = config.channels.signal.serviceURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if signalURL.hasPrefix("http://"), !signalURL.contains("127.0.0.1"), !signalURL.contains("localhost") {
                findings.append(
                    SecurityAuditFinding(
                        id: "channels.signal.insecure-service-url",
                        severity: .warning,
                        summary: "Signal bridge URL is configured without TLS",
                        detail: "Signal adapter uses non-local insecure URL '\(config.channels.signal.serviceURL)'.",
                        recommendation: "Use an HTTPS endpoint for non-local Signal bridge deployments."
                    )
                )
            }
        }

        let authMode = config.gateway.effectiveAuthMode.rawValue
        if authMode == GatewayAuthMode.none.rawValue {
            findings.append(
                SecurityAuditFinding(
                    id: "gateway.auth-mode-unsafe",
                    severity: .error,
                    summary: "Gateway auth mode appears unsafe",
                    detail: "Gateway auth mode is '\(authMode)'.",
                    recommendation: "Use token-based authentication for gateway access."
                )
            )
        }
        for (providerID, provider) in config.models.providers {
            let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, provider.enabled else {
                continue
            }
            switch provider.auth {
            case nil:
                let normalizedBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isLocalRuntime = normalizedID == "ollama"
                    || normalizedID == "vllm"
                    || normalizedBaseURL.hasPrefix("http://127.0.0.1")
                    || normalizedBaseURL.hasPrefix("http://localhost")
                if !isLocalRuntime {
                    findings.append(
                        SecurityAuditFinding(
                            id: "models.providers.\(normalizedID).auth-none",
                            severity: .warning,
                            summary: "Provider service uses auth mode none",
                            detail: "Provider '\(normalizedID)' is enabled without auth and baseURL '\(provider.baseURL)'.",
                            recommendation: "Use token-based auth for non-local providers."
                        )
                    )
                }
            case .awsSDK?:
                let region = provider.region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if region.isEmpty {
                    findings.append(
                        SecurityAuditFinding(
                            id: "models.providers.\(normalizedID).region-missing",
                            severity: .warning,
                            summary: "AWS-backed provider is missing region",
                            detail: "Provider '\(normalizedID)' is enabled with `auth = aws-sdk` but no region is configured.",
                            recommendation: "Set `models.providers.\(normalizedID).region` to the intended AWS region."
                        )
                    )
                }
            case .apiKey?, .oauth?, .token?:
                break
            }
        }

        if config.models.local.enabled,
           (config.models.local.modelPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        {
            findings.append(
                SecurityAuditFinding(
                    id: "models.local.model-path-missing",
                    severity: .warning,
                    summary: "Local model provider is enabled without a model path",
                    detail: "Local provider is enabled but no primary model path is configured.",
                    recommendation: "Set `models.local.modelPath` or disable local provider."
                )
            )
        }

        return findings
    }

    private static func checkPathPermissions(_ paths: [URL]) -> [SecurityAuditFinding] {
        var findings: [SecurityAuditFinding] = []
        let uniquePaths = Array(Set(paths.map(\.path))).sorted()

        for path in uniquePaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            guard let mode = self.posixMode(for: url) else {
                continue
            }

            let groupOtherMask = mode & 0o077
            if groupOtherMask == 0 {
                continue
            }

            let severity: SecurityAuditSeverity = (mode & 0o002) != 0 ? .error : .warning
            findings.append(
                SecurityAuditFinding(
                    id: "filesystem.permissions.\(url.lastPathComponent)",
                    severity: severity,
                    summary: "Filesystem permissions are more permissive than recommended",
                    detail: "Path '\(url.path)' has mode \(self.octalString(mode)).",
                    filePath: url.path,
                    recommendation: "Use restrictive permissions (`0700` for directories, `0600` for files containing state/config data)."
                )
            )
        }
        return findings
    }

    private static func checkPlaintextSecretFiles(_ files: [URL]) -> [SecurityAuditFinding] {
        var findings: [SecurityAuditFinding] = []
        let uniquePaths = Array(Set(files.map(\.path))).sorted()

        for path in uniquePaths {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else {
                continue
            }
            guard self.containsPlaintextSecretPattern(in: text) else {
                continue
            }
            findings.append(
                SecurityAuditFinding(
                    id: "plaintext.file.\(url.lastPathComponent)",
                    severity: .warning,
                    summary: "Potential plaintext secrets detected in file",
                    detail: "Detected secret-like JSON keys with non-empty values in '\(url.path)'.",
                    filePath: url.path,
                    recommendation: "Remove committed secrets and migrate values to environment variables or secure credential storage."
                )
            )
        }
        return findings
    }

    private static func checkReplayLedgerIntegrity(
        _ envelopes: [ReplayEventEnvelope],
        signer: (any ReplayLedgerSigner)?,
        requireSignatures: Bool
    ) -> (result: ReplayLedgerVerificationResult, findings: [SecurityAuditFinding]) {
        let result = ReplayLedgerVerifier.verify(
            envelopes: envelopes,
            signer: signer,
            requireSignatureVerification: requireSignatures
        )
        guard !result.isValid else {
            return (result, [])
        }

        return (
            result,
            [
                SecurityAuditFinding(
                    id: "replay.ledger.integrity.invalid",
                    severity: .error,
                    summary: "Replay ledger integrity verification failed",
                    detail: result.failureReason ?? "Replay ledger chain failed verification.",
                    recommendation: "Regenerate replay ledger signatures and investigate tampering or storage corruption."
                ),
            ]
        )
    }

    private static func containsPlaintextSecretPattern(in text: String) -> Bool {
        let patterns = [
            "\"botToken\"\\s*:\\s*\"[^\"]+\"",
            "\"apiKey\"\\s*:\\s*\"[^\"]+\"",
            "\"accessToken\"\\s*:\\s*\"[^\"]+\"",
            "\"webhookVerifyToken\"\\s*:\\s*\"[^\"]+\"",
        ]
        for pattern in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private static func posixMode(for url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let number = attrs[.posixPermissions] as? NSNumber {
            return number.intValue & 0o777
        }
        if let int = attrs[.posixPermissions] as? Int {
            return int & 0o777
        }
        return nil
    }

    private static func octalString(_ mode: Int) -> String {
        String(format: "0%03o", mode & 0o777)
    }

    private static func severityRank(_ severity: SecurityAuditSeverity) -> Int {
        switch severity {
        case .error:
            return 3
        case .warning:
            return 2
        case .info:
            return 1
        }
    }
}
