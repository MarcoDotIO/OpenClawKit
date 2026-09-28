import Foundation
import OpenClawProtocol

// Non-throwing ports of upstream `superRefine` checks. Upstream rejects these configs at startup;
// the SDK reports them so control-plane UIs can explain the problem before writing.

extension OpenClawConfigDocument {
    /// Every cross-field problem the upstream schema would reject (never throws).
    /// - Returns: Validation issues with dotted paths.
    public func validationIssues() -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        issues += self.agents?.validationIssues() ?? []
        issues += self.gateway?.validationIssues() ?? []
        issues += Self.bindingValidationIssues(self.bindings ?? [])
        issues += self.tools?.validationIssues(path: "tools") ?? []
        for (id, entry) in self.agents?.entries ?? [:] {
            issues += entry.tools?.validationIssues(path: "agents.entries.\(id).tools") ?? []
        }
        issues += self.talk?.validationIssues() ?? []
        issues += self.hooks?.validationIssues() ?? []
        issues += self.mcp?.validationIssues() ?? []
        issues += self.channels?.validationIssues() ?? []
        return issues.sorted { ($0.path, $0.message) < ($1.path, $1.message) }
    }

    static func invalid(_ path: String, _ message: String) -> ConfigDecodeIssue {
        ConfigDecodeIssue(path: path, message: message, kind: .invalidValue)
    }

    // MARK: Bindings

    static func bindingValidationIssues(_ bindings: [AgentBinding]) -> [ConfigDecodeIssue] {
        bindings.enumerated().compactMap { index, binding in
            guard case .acp(let acp) = binding else { return nil }
            let peerID = acp.match?.peer?.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return peerID.isEmpty
                ? invalid("bindings[\(index)].match.peer", "ACP bindings require match.peer.id to target a concrete conversation.")
                : nil
        }
    }

    /// Projects route bindings onto the SDK ``AgentsConfig/routeAgentMap`` (`channel[:accountID[:peerID]] → agentID`).
    ///
    /// Bindings are evaluated in array order and the first match wins upstream; the SDK map looks up
    /// the most specific key first, which agrees only for equivalent keys. Bindings that the map cannot
    /// express (guild/team/role matches, non-direct peers, ACP bindings) stay in the document and are
    /// reported. An omitted `accountId` means the channel's default account upstream but "any account"
    /// in the SDK map; `*` maps to "any account".
    /// - Parameters:
    ///   - bindings: Document bindings.
    ///   - issues: Receives one issue per unexpressible binding.
    /// - Returns: Route map.
    public static func routeAgentMap(from bindings: [AgentBinding], issues: inout [ConfigDecodeIssue]) -> [String: String] {
        var map: [String: String] = [:]
        for (index, binding) in bindings.enumerated() {
            guard case .route(let route) = binding else {
                if case .acp = binding {
                    issues.append(ConfigDecodeIssue(path: "bindings[\(index)]", message: "ACP bindings have no SDK route-map form.", kind: .invalidValue))
                }
                continue
            }
            guard let agentID = ConfigValueSupport.nonEmpty(route.agentId),
                  let match = route.match, let channel = ConfigValueSupport.nonEmpty(match.channel)
            else {
                issues.append(invalid("bindings[\(index)]", "Route bindings require agentId and match.channel."))
                continue
            }
            let hasScopedMatch = ConfigValueSupport.nonEmpty(match.guildId) != nil
                || ConfigValueSupport.nonEmpty(match.teamId) != nil
                || !(match.roles ?? []).isEmpty
            let peerKind = match.peer?.kind?.lowercased()
            if hasScopedMatch || (match.peer != nil && peerKind != "direct" && peerKind != "dm") {
                issues.append(ConfigDecodeIssue(
                    path: "bindings[\(index)].match",
                    message: "Guild, team, role and group/channel peer matches have no SDK route-map form; the binding stays in openclaw.json.",
                    kind: .invalidValue
                ))
                continue
            }
            let accountID = match.accountId == "*" ? nil : ConfigValueSupport.nonEmpty(match.accountId)
            let peerID = ConfigValueSupport.nonEmpty(match.peer?.id)
            if peerID != nil, accountID == nil {
                // The SDK key `channel:peer` would be read as `channel:account`.
                issues.append(ConfigDecodeIssue(
                    path: "bindings[\(index)].match",
                    message: "Peer matches without a concrete accountId have no SDK route-map form; the binding stays in openclaw.json.",
                    kind: .invalidValue
                ))
                continue
            }
            let key = AgentsConfig.routeKey(channel: channel, accountID: accountID, peerID: peerID)
            if map[key] == nil {
                map[key] = agentID
            }
        }
        return map
    }

    /// Reverse of ``routeAgentMap(from:issues:)``: route bindings for an SDK route map, most specific first.
    /// - Parameter routeAgentMap: SDK route map.
    /// - Returns: Route bindings.
    public static func bindings(fromRouteAgentMap routeAgentMap: [String: String]) -> [AgentBinding] {
        let parsed = routeAgentMap.compactMap { key, agentID -> (parts: [String], agentID: String)? in
            let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let channel = parts.first, !channel.isEmpty, !agentID.isEmpty else { return nil }
            return (parts, agentID)
        }
        return parsed
            .sorted { lhs, rhs in
                lhs.parts.count != rhs.parts.count ? lhs.parts.count > rhs.parts.count : lhs.parts.joined(separator: ":") < rhs.parts.joined(separator: ":")
            }
            .map { entry in
                var match = BindingMatch()
                match.channel = entry.parts[0]
                // `channel` alone matches every account in the SDK map, which upstream spells `*`.
                match.accountId = entry.parts.count > 1 && !entry.parts[1].isEmpty ? entry.parts[1] : "*"
                if entry.parts.count > 2, !entry.parts[2].isEmpty {
                    var peer = BindingMatch.Peer()
                    peer.kind = "direct"
                    peer.id = entry.parts[2]
                    match.peer = peer
                }
                var route = RouteBinding()
                route.agentId = entry.agentID
                route.match = match
                return .route(route)
            }
    }
}

extension OpenClawConfigDocument.Agents {
    /// Roster checks from upstream `AgentsSchema.superRefine`.
    /// - Returns: Issues (empty when valid).
    public func validationIssues() -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        let entries = self.entries ?? [:]
        if entries.isEmpty {
            issues.append(OpenClawConfigDocument.invalid("agents.entries", "agents.entries must contain at least one configured agent"))
        }
        var firstKeyByID: [String: String] = [:]
        for key in self.entryOrder {
            if !Self.isValidEntryKey(key) {
                issues.append(OpenClawConfigDocument.invalid("agents.entries.\(key)", "Invalid agent id"))
            }
            let id = OpenClawConfigDocument.normalizeAgentID(key)
            if let first = firstKeyByID[id] {
                issues.append(OpenClawConfigDocument.invalid(
                    "agents.entries.\(key)",
                    "agents.entries keys \"\(first)\" and \"\(key)\" resolve to the same agent id \"\(id)\"; rename one key so each agent has a unique id"
                ))
            } else {
                firstKeyByID[id] = key
            }
        }
        let marked = entries.values.filter { $0.default == true }.count
        if marked > 1 {
            issues.append(OpenClawConfigDocument.invalid("agents.entries", "agents.entries must contain at most one default=true entry (found \(marked))"))
        }
        if self.ownership == "explicit", marked > 0 {
            issues.append(OpenClawConfigDocument.invalid("agents.ownership", "agents.ownership=explicit cannot be combined with a legacy default=true marker"))
        }
        if entries.count > 1, marked == 0, self.ownership != "explicit" {
            issues.append(OpenClawConfigDocument.invalid(
                "agents.ownership",
                "multi-agent rosters require agents.ownership=\"explicit\" or one legacy default=true marker; add agents.ownership=\"explicit\" or run openclaw doctor"
            ))
        }
        return issues
    }

    /// `^[a-z0-9_][a-z0-9_-]{0,63}$` (case-insensitive).
    static func isValidEntryKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.count <= 64 else { return false }
        func allowed(_ scalar: Unicode.Scalar, dash: Bool) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
                || (dash && scalar == "-")
        }
        return allowed(first, dash: false) && key.unicodeScalars.dropFirst().allSatisfy { allowed($0, dash: true) }
    }
}

extension OpenClawConfigDocument.Gateway {
    /// Gateway checks from upstream `GatewayConfigSchema.superRefine` and field refinements.
    /// - Returns: Issues (empty when valid).
    public func validationIssues() -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        func add(_ path: String, _ message: String) {
            issues.append(OpenClawConfigDocument.invalid(path, message))
        }
        if let port, !(1...65_535).contains(port) {
            add("gateway.port", "gateway.port must be between 1 and 65535")
        }
        if let publicOrigin, !GatewayConfig.isValidPublicOrigin(publicOrigin) {
            add("gateway.publicOrigin", "gateway.publicOrigin must be a bare HTTPS origin; HTTP is allowed only for localhost, 127.0.0.1, or [::1]")
        }
        if let ingress = self.portals?.ingress {
            if let domain = ingress.domain {
                if !Self.isValidPortalIngressDomain(domain) {
                    add("gateway.portals.ingress.domain", "Portal ingress domain must be a bare DNS domain")
                }
                let origins = [self.publicOrigin].compactMap { $0 } + (self.controlUi?.allowedOrigins ?? [])
                if origins.contains(where: { Self.portalIngress(domain, conflictsWith: $0) }) {
                    add("gateway.portals.ingress.domain", "Portal ingress must use a separate domain from Gateway and Control UI origins")
                }
            }
            if let ingressPort = ingress.port, ingressPort == self.effectivePort {
                add("gateway.portals.ingress.port", "Portal ingress port must differ from the Gateway port")
            }
        }
        if let roles {
            let definitions = roles.definitions ?? [:]
            if definitions.isEmpty {
                add("gateway.roles.definitions", "gateway.roles.definitions must contain at least one role definition")
            }
            if let defaultRole = roles.default, definitions[defaultRole] == nil {
                add("gateway.roles.default", "gateway.roles.default must name a configured role definition")
            }
        }
        if let edgeAuth = self.remote?.edgeAuth, let message = GatewayEdgeAuthHeaders.validationError(edgeAuth.keys.sorted()) {
            add("gateway.remote.edgeAuth", message)
        }
        if self.auth?.mode == "trusted-proxy" {
            if ConfigValueSupport.nonEmpty(self.auth?.trustedProxy?.userHeader) == nil {
                add("gateway.auth.trustedProxy.userHeader", "userHeader is required for trusted-proxy mode")
            }
            if (self.trustedProxies ?? []).isEmpty {
                add("gateway.trustedProxies", "gateway.trustedProxies must contain at least one proxy IP when auth.mode is trusted-proxy.")
            }
        }
        if let mode = self.auth?.mode, mode == "token" || mode == "password",
           let secret = self.auth?.sharedSecret?.plaintext, GatewaySharedSecretPolicy.isPlaceholder(secret)
        {
            add("gateway.auth.\(mode)", "gateway.auth \(mode) must not be blank or a placeholder value")
        }
        return issues
    }

    /// Upstream `isValidPortalIngressDomain`.
    static func isValidPortalIngressDomain(_ domain: String) -> Bool {
        guard domain.count <= 220, domain.contains("."), !MigrationSupport.isIPLiteral(domain) else { return false }
        return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard let first = label.first, let last = label.last, label.count <= 63 else { return false }
            func alphanumeric(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
            return alphanumeric(first) && alphanumeric(last) && label.allSatisfy { alphanumeric($0) || $0 == "-" }
        }
    }

    /// Upstream `portalIngressConflictsWithOrigin`.
    static func portalIngress(_ domain: String, conflictsWith origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        let suffix = domain.lowercased()
        return host == suffix || host.hasSuffix(".\(suffix)")
    }
}

extension MigrationSupport {
    static func isIPLiteral(_ value: String) -> Bool {
        ConfigMigrationRules.isIPAddress(value)
    }
}

extension OpenClawConfigDocument.Tools {
    /// Tool-policy checks: `allow` + `alsoAllow` in one scope, and `exec.mode` combined with legacy keys.
    /// - Parameter path: Scope path.
    /// - Returns: Issues.
    public func validationIssues(path: String) -> [ConfigDecodeIssue] {
        var issues = OpenClawConfigDocument.toolPolicyIssues(allow: self.allow, alsoAllow: self.alsoAllow, path: path)
        for (provider, policy) in self.byProvider ?? [:] {
            issues += OpenClawConfigDocument.toolPolicyIssues(allow: policy.allow, alsoAllow: policy.alsoAllow, path: "\(path).byProvider.\(provider)")
        }
        issues += self.exec?.validationIssues(path: "\(path).exec") ?? []
        return issues
    }
}

extension OpenClawConfigDocument.AgentTools {
    /// Tool-policy checks for one agent scope.
    /// - Parameter path: Scope path.
    /// - Returns: Issues.
    public func validationIssues(path: String) -> [ConfigDecodeIssue] {
        var issues = OpenClawConfigDocument.toolPolicyIssues(allow: self.allow, alsoAllow: self.alsoAllow, path: path)
        for (provider, policy) in self.byProvider ?? [:] {
            issues += OpenClawConfigDocument.toolPolicyIssues(allow: policy.allow, alsoAllow: policy.alsoAllow, path: "\(path).byProvider.\(provider)")
        }
        issues += self.exec?.validationIssues(path: "\(path).exec") ?? []
        return issues
    }
}

extension OpenClawConfigDocument.Exec {
    /// Upstream check: `mode` must not be combined with the legacy `security`/`ask` pair.
    /// - Parameter path: Exec scope path.
    /// - Returns: Issues.
    public func validationIssues(path: String) -> [ConfigDecodeIssue] {
        guard self.mode != nil, self.security != nil || self.ask != nil else { return [] }
        var message = "\(path).mode cannot be combined with \(path).security or \(path).ask"
        if let security = self.security.flatMap(ExecSecurity.init(rawValue:)),
           let ask = self.ask.flatMap(ExecAsk.init(rawValue:)),
           let exact = ExecMode.exact(security: security, ask: ask)
        {
            message += "; use mode \"\(exact.rawValue)\""
        }
        return [OpenClawConfigDocument.invalid(path, message)]
    }
}

extension OpenClawConfigDocument {
    static func toolPolicyIssues(allow: [String]?, alsoAllow: [String]?, path: String) -> [ConfigDecodeIssue] {
        guard !(allow ?? []).isEmpty, !(alsoAllow ?? []).isEmpty else { return [] }
        return [invalid(path, "\(path) sets both allow and alsoAllow; run openclaw doctor --fix to merge them when the grants are preserved")]
    }
}

extension OpenClawConfigDocument.MCP {
    /// MCP server checks (`zod-schema.mcp-server.ts`).
    /// - Returns: Issues.
    public func validationIssues() -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        if self.servers?[Self.reservedServerName] != nil {
            issues.append(OpenClawConfigDocument.invalid("mcp.servers.__proto__", "MCP server name \"__proto__\" is reserved; rename the server"))
        }
        for (name, server) in self.servers ?? [:] {
            let path = "mcp.servers.\(name)"
            let transport = server.canonicalTransport
            if transport == "stdio", ConfigValueSupport.nonEmpty(server.command) == nil {
                issues.append(OpenClawConfigDocument.invalid("\(path).command", "stdio MCP servers require a non-empty command"))
            }
            if server.oauth?.dictionaryValue?["identity"]?.stringValue == "per-requester" {
                if server.auth != "oauth" || ConfigValueSupport.nonEmpty(server.url) == nil {
                    issues.append(OpenClawConfigDocument.invalid("\(path).oauth", "per-requester OAuth requires auth \"oauth\" and a url"))
                }
                if server.oauth?.dictionaryValue?["authProfileId"] != nil {
                    issues.append(OpenClawConfigDocument.invalid("\(path).oauth.authProfileId", "per-requester OAuth cannot use authProfileId"))
                }
                if server.command != nil || transport == "stdio" {
                    issues.append(OpenClawConfigDocument.invalid("\(path).command", "per-requester OAuth cannot use a stdio command"))
                }
            }
            for legacy in ["connectTimeout", "connect_timeout", "timeout", "workingDirectory", "disabled", "type",
                           "supports_parallel_tool_calls", "ssl_verify", "client_cert", "client_key"]
            where server.additionalProperties[legacy] != nil {
                issues.append(ConfigDecodeIssue(path: "\(path).\(legacy)", message: "\(path).\(legacy) is a legacy alias; run openclaw doctor --fix", kind: .legacyKey))
            }
        }
        return issues
    }
}

extension OpenClawConfigDocument.Channels {
    /// Generic channel checks (DM policy allowlists, multi-account defaults, channel-local ACP bindings).
    /// - Returns: Issues.
    public func validationIssues() -> [ConfigDecodeIssue] {
        var issues: [ConfigDecodeIssue] = []
        for (channelID, block) in self.entries {
            let path = "channels.\(channelID)"
            let allowFrom = (block.allowFrom ?? []).map(\.stringValue)
            if block.dmPolicy == "open", !allowFrom.contains("*") {
                issues.append(OpenClawConfigDocument.invalid("\(path).allowFrom", "dmPolicy \"open\" requires allowFrom to contain \"*\""))
            }
            if block.dmPolicy == "allowlist", allowFrom.isEmpty {
                issues.append(OpenClawConfigDocument.invalid("\(path).allowFrom", "dmPolicy \"allowlist\" requires a non-empty allowFrom"))
            }
            let accounts = block.accounts ?? [:]
            if accounts.count >= 2, block.defaultAccount == nil, accounts["default"] == nil {
                issues.append(OpenClawConfigDocument.invalid(
                    "\(path).defaultAccount",
                    "\(path) has \(accounts.count) accounts without defaultAccount or accounts.default; fallback routing can pick an unexpected account"
                ))
            }
            if let defaultAccount = block.defaultAccount, !accounts.isEmpty, accounts[defaultAccount] == nil {
                issues.append(OpenClawConfigDocument.invalid(
                    "\(path).defaultAccount",
                    "\(path).defaultAccount names unknown account \"\(defaultAccount)\" (configured: \(accounts.keys.sorted().joined(separator: ", ")))"
                ))
            }
            if block.additionalProperties["bindings"]?.dictionaryValue?["acp"] != nil {
                issues.append(OpenClawConfigDocument.invalid("\(path).bindings.acp", "channel-local bindings.acp is not supported; use top-level bindings[] entries"))
            }
        }
        return issues
    }
}
