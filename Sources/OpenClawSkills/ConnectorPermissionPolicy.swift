import Foundation
import OpenClawCore

/// Permission grant state for one connector.
public struct ConnectorPermissionGrant: Sendable, Equatable {
    public let connector: SkillConnectorType
    public let scopes: Set<String>
    public let consentGranted: Bool

    /// Creates a connector permission grant.
    public init(connector: SkillConnectorType, scopes: Set<String>, consentGranted: Bool) {
        self.connector = connector
        self.scopes = scopes
        self.consentGranted = consentGranted
    }
}

/// Permission check decision for connector-backed skill execution.
public enum ConnectorPermissionDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

/// Permission policy for personal-data connector skills.
public actor ConnectorPermissionPolicy {
    private var grants: [SkillConnectorType: ConnectorPermissionGrant] = [:]

    /// Creates a connector permission policy.
    /// - Parameter initialGrants: Optional pre-approved grants.
    public init(initialGrants: [ConnectorPermissionGrant] = []) {
        for grant in initialGrants {
            self.grants[grant.connector] = grant
        }
    }

    /// Grants connector permission scopes.
    /// - Parameters:
    ///   - connector: Connector type.
    ///   - scopes: Approved scope strings.
    ///   - consentGranted: Consent state.
    public func grant(
        connector: SkillConnectorType,
        scopes: [String],
        consentGranted: Bool = true
    ) {
        let normalizedScopes = Set(
            scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        self.grants[connector] = ConnectorPermissionGrant(
            connector: connector,
            scopes: normalizedScopes,
            consentGranted: consentGranted
        )
    }

    /// Revokes connector permissions.
    /// - Parameter connector: Connector type.
    public func revoke(connector: SkillConnectorType) {
        self.grants.removeValue(forKey: connector)
    }

    /// Returns currently granted connector states.
    public func allGrants() -> [ConnectorPermissionGrant] {
        self.grants.values.sorted { $0.connector.rawValue < $1.connector.rawValue }
    }

    /// Evaluates whether a skill is allowed to use its declared connectors.
    /// - Parameter skill: Skill definition being invoked.
    /// - Returns: Permission decision.
    public func evaluate(skill: SkillDefinition) -> ConnectorPermissionDecision {
        guard !skill.metadata.connectors.isEmpty else {
            return .allow
        }

        for permission in skill.metadata.connectors {
            guard let grant = self.grants[permission.connector] else {
                return .deny(
                    reason: "Missing grant for connector '\(permission.connector.rawValue)'"
                )
            }

            if permission.consent != .none && !grant.consentGranted {
                return .deny(
                    reason: "Consent not granted for connector '\(permission.connector.rawValue)'"
                )
            }

            let requiredScopes = Set(
                permission.scopes
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            if !requiredScopes.isSubset(of: grant.scopes) {
                return .deny(
                    reason: "Missing scope(s) \(requiredScopes.subtracting(grant.scopes).sorted()) for connector '\(permission.connector.rawValue)'"
                )
            }
        }
        return .allow
    }

    /// Enforces connector permissions for one skill invocation.
    /// - Parameter skill: Skill definition being invoked.
    public func enforce(skill: SkillDefinition) throws {
        let decision = self.evaluate(skill: skill)
        switch decision {
        case .allow:
            return
        case .deny(let reason):
            throw OpenClawCoreError.unavailable(
                "Connector permission denied for skill '\(skill.name)': \(reason)"
            )
        }
    }
}
