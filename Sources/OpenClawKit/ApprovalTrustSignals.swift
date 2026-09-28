import Foundation
#if compiler(>=6.4) && canImport(TrustInsights) && os(iOS) && !targetEnvironment(macCatalyst)
import TrustInsights
#endif

/// A sensitive operation that a user approves on this device.
public enum OpenClawSensitiveOperation: Sendable, Hashable {
    /// Approving a pending device pairing request (`device.pair.approve`).
    case approveDevicePairing(requestId: String)
    /// Resolving an exec approval (`exec.approval.resolve`) with a decision such as `allow-once`,
    /// `allow-always`, or `deny`.
    case resolveExecApproval(id: String, decision: String)
    /// Rotating a paired device's token.
    case rotateDeviceToken(deviceId: String)

    /// Request identifier used to correlate the evaluation with the operation.
    public var requestID: String {
        switch self {
        case let .approveDevicePairing(requestId):
            return requestId
        case let .resolveExecApproval(id, _):
            return id
        case let .rotateDeviceToken(deviceId):
            return deviceId
        }
    }

    /// Whether the operation grants lasting access (pairing, token rotation, `allow-always`).
    public var grantsPersistentAccess: Bool {
        switch self {
        case .approveDevicePairing, .rotateDeviceToken:
            return true
        case let .resolveExecApproval(_, decision):
            let normalized = decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "allow-always" || normalized == "always" || normalized == "allowalways"
        }
    }

    /// Whether the operation denies rather than grants.
    public var isDenial: Bool {
        guard case let .resolveExecApproval(_, decision) = self else { return false }
        let normalized = decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "deny" || normalized == "reject"
    }
}

/// Coaching-risk signal for a sensitive operation.
public enum OpenClawCoachingRisk: String, Sendable, CaseIterable {
    /// No elevated risk detected (or the evaluation was inconclusive).
    case none
    /// Medium likelihood that the user is being coached by someone else.
    case medium
    /// High likelihood that the user is being coached by someone else.
    case high
    /// No signal is available (unsupported OS, not authorized, or the evaluation failed).
    case unavailable
}

/// Extra confirmation required before a sensitive operation is sent.
public enum OpenClawApprovalFriction: String, Sendable, CaseIterable, Comparable {
    /// Proceed normally.
    case none
    /// Show an explicit warning before sending.
    case warn
    /// Show an explicit warning and require device-owner re-authentication (LocalAuthentication).
    case reauthenticate

    private var rank: Int {
        switch self {
        case .none: return 0
        case .warn: return 1
        case .reauthenticate: return 2
        }
    }

    /// Orders frictions from least to most.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Source of coaching-risk signals for approval flows.
///
/// The shipped implementation, ``TrustInsightsApprovalSignals``, uses TrustInsights'
/// `IsLikelyBeingCoachedInsight` on iOS 27. The signal is local-only friction: the gateway does not
/// verify the signed payload and no protocol field changes.
public protocol OpenClawApprovalTrustSignals: Sendable {
    /// Returns the coaching risk for an operation (never prompts for authorization).
    /// - Parameter operation: Operation about to be approved.
    /// - Returns: Risk level.
    func coachingRisk(for operation: OpenClawSensitiveOperation) async -> OpenClawCoachingRisk

    /// Records whether friction was applied after the user decided.
    /// - Parameters:
    ///   - operation: Operation that was decided.
    ///   - frictionApplied: Whether additional friction was shown.
    func recordOutcome(_ operation: OpenClawSensitiveOperation, frictionApplied: Bool) async
}

/// Trust-signal source that never reports a risk.
public struct NoopApprovalTrustSignals: OpenClawApprovalTrustSignals {
    /// Creates a no-op signal source.
    public init() {}

    /// Always returns ``OpenClawCoachingRisk/unavailable``.
    public func coachingRisk(for operation: OpenClawSensitiveOperation) async -> OpenClawCoachingRisk {
        .unavailable
    }

    /// Does nothing.
    public func recordOutcome(_ operation: OpenClawSensitiveOperation, frictionApplied: Bool) async {}
}

/// Maps coaching risk to approval friction.
///
/// Default policy: `high` risk requires re-authentication plus a warning for operations that grant
/// access (pairing, token rotation, any exec allow) and a warning otherwise; `medium` risk shows a
/// warning for operations that grant persistent access; denials never get friction.
public struct OpenClawApprovalFrictionPolicy: Sendable, Equatable {
    /// Friction for `high` risk on access-granting operations.
    public var highRiskFriction: OpenClawApprovalFriction
    /// Friction for `medium` risk on persistent-access operations.
    public var mediumRiskFriction: OpenClawApprovalFriction

    /// Creates a friction policy.
    /// - Parameters:
    ///   - highRiskFriction: Friction for `high` risk.
    ///   - mediumRiskFriction: Friction for `medium` risk.
    public init(highRiskFriction: OpenClawApprovalFriction = .reauthenticate, mediumRiskFriction: OpenClawApprovalFriction = .warn) {
        self.highRiskFriction = highRiskFriction
        self.mediumRiskFriction = mediumRiskFriction
    }

    /// Default policy.
    public static let `default` = OpenClawApprovalFrictionPolicy()

    /// Returns the friction to apply.
    /// - Parameters:
    ///   - risk: Coaching risk.
    ///   - operation: Operation about to be approved.
    /// - Returns: Required friction.
    public func friction(for risk: OpenClawCoachingRisk, operation: OpenClawSensitiveOperation) -> OpenClawApprovalFriction {
        guard !operation.isDenial else { return .none }
        switch risk {
        case .high:
            return self.highRiskFriction
        case .medium:
            return operation.grantsPersistentAccess ? self.mediumRiskFriction : .none
        case .none, .unavailable:
            return .none
        }
    }
}

/// Evaluates approval friction and records the outcome.
///
/// Typical flow: call ``evaluate(_:)`` before sending `device.pair.approve` or
/// `exec.approval.resolve`, apply the returned friction in the UI (warning and/or
/// LocalAuthentication), then call ``recordOutcome(_:friction:)`` once the user decided.
public struct OpenClawApprovalGate: Sendable {
    /// Signal source.
    public let signals: any OpenClawApprovalTrustSignals
    /// Friction policy.
    public let policy: OpenClawApprovalFrictionPolicy

    /// Result of evaluating an operation.
    public struct Evaluation: Sendable, Equatable {
        /// Operation that was evaluated.
        public let operation: OpenClawSensitiveOperation
        /// Coaching risk.
        public let risk: OpenClawCoachingRisk
        /// Required friction.
        public let friction: OpenClawApprovalFriction

        /// Whether any extra friction is required.
        public var requiresFriction: Bool { self.friction != .none }
    }

    /// Creates an approval gate.
    /// - Parameters:
    ///   - signals: Signal source (defaults to ``OpenClawApprovalTrustSignalsFactory/makeDefault()``).
    ///   - policy: Friction policy.
    public init(signals: (any OpenClawApprovalTrustSignals)? = nil, policy: OpenClawApprovalFrictionPolicy = .default) {
        self.signals = signals ?? OpenClawApprovalTrustSignalsFactory.makeDefault()
        self.policy = policy
    }

    /// Evaluates the friction required for an operation.
    /// - Parameter operation: Operation about to be approved.
    /// - Returns: Risk and friction.
    public func evaluate(_ operation: OpenClawSensitiveOperation) async -> Evaluation {
        let risk = await self.signals.coachingRisk(for: operation)
        return Evaluation(operation: operation, risk: risk, friction: self.policy.friction(for: risk, operation: operation))
    }

    /// Records the decision outcome.
    /// - Parameters:
    ///   - evaluation: Evaluation returned by ``evaluate(_:)``.
    ///   - friction: Friction actually shown (defaults to the evaluated friction).
    public func recordOutcome(_ evaluation: Evaluation, friction: OpenClawApprovalFriction? = nil) async {
        let applied = friction ?? evaluation.friction
        await self.signals.recordOutcome(evaluation.operation, frictionApplied: applied != .none)
    }
}

/// Creates the platform trust-signal source.
public enum OpenClawApprovalTrustSignalsFactory {
    /// Returns ``TrustInsightsApprovalSignals`` on iOS 27, otherwise ``NoopApprovalTrustSignals``.
    public static func makeDefault() -> any OpenClawApprovalTrustSignals {
        #if compiler(>=6.4) && canImport(TrustInsights) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            return TrustInsightsApprovalSignals()
        }
        #endif
        return NoopApprovalTrustSignals()
    }
}

#if compiler(>=6.4) && canImport(TrustInsights) && os(iOS) && !targetEnvironment(macCatalyst)
/// TrustInsights-backed coaching-risk signals (iOS 27).
///
/// Pairing and token rotation are evaluated as `.account` operations, exec approvals as
/// `.resourceUse`. ``coachingRisk(for:)`` never prompts: it returns ``OpenClawCoachingRisk/unavailable``
/// unless TrustInsights is already authorized. Call ``requestAuthorization()`` only from an explicit
/// user action (for example a Settings toggle).
@available(iOS 27.0, *)
@available(visionOS, unavailable)
@available(macCatalyst, unavailable)
public actor TrustInsightsApprovalSignals: OpenClawApprovalTrustSignals {
    private let evaluator = InsightEvaluator()
    private var evaluations: [OpenClawSensitiveOperation: InsightEvaluation<IsLikelyBeingCoachedInsight>] = [:]

    /// Creates a TrustInsights signal source.
    public init() {}

    /// Requests TrustInsights authorization. Call only from an explicit user action.
    /// - Returns: Whether the app is authorized afterwards.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        let context = Self.context(for: .approveDevicePairing(requestId: "authorization"))
        do {
            return try await self.evaluator.requestAuthorization(for: context) == .authorized
        } catch {
            return false
        }
    }

    /// Returns the coaching risk without prompting.
    public func coachingRisk(for operation: OpenClawSensitiveOperation) async -> OpenClawCoachingRisk {
        let context = Self.context(for: operation)
        do {
            guard try await self.evaluator.authorizationStatus(for: context) == .authorized else {
                return .unavailable
            }
            let evaluation = try await self.evaluator.requestEvaluation(context: context)
            self.evaluations[operation] = evaluation
            switch evaluation.insight.outcome {
            case let .success(value):
                switch value {
                case .high: return .high
                case .medium: return .medium
                case .unknown: return .none
                @unknown default: return .none
                }
            case .failure:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    /// Reports how the evaluation was used.
    public func recordOutcome(_ operation: OpenClawSensitiveOperation, frictionApplied: Bool) async {
        guard let evaluation = self.evaluations.removeValue(forKey: operation) else { return }
        evaluation.reportConsumption(
            frictionApplied ? .usedIncreasedFriction : .usedUnchangedFriction,
            insightsUsed: [evaluation.insight])
    }

    private static func context(
        for operation: OpenClawSensitiveOperation) -> InsightEvaluator.InsightContext<InsightEvaluator.InsightRequest<IsLikelyBeingCoachedInsight>>
    {
        let category: InsightEvaluator.OperationCategory
        switch operation {
        case .approveDevicePairing, .rotateDeviceToken:
            category = .account
        case .resolveExecApproval:
            category = .resourceUse
        }
        var context = InsightEvaluator.InsightContext(
            operationCategory: category,
            requestedEvaluations: (IsLikelyBeingCoachedInsight.request(schema: .version1)))
        context.requestID = operation.requestID
        return context
    }
}
#endif
