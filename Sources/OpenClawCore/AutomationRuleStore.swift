import Foundation

/// Trigger strategy for proactive automation rules.
public enum AutomationTriggerType: String, Codable, Sendable, Equatable {
    case interval
    case diagnosticEvent
}

/// Trigger configuration for one automation rule.
public struct AutomationTrigger: Codable, Sendable, Equatable {
    /// Trigger type.
    public let type: AutomationTriggerType
    /// Interval (seconds) for recurring rule execution.
    public let intervalSeconds: Int?
    /// Runtime diagnostics subsystem filter for event triggers.
    public let subsystem: String?
    /// Runtime diagnostics event-name filter for event triggers.
    public let eventName: String?

    /// Creates an interval trigger.
    /// - Parameter intervalSeconds: Minimum interval between executions.
    public init(intervalSeconds: Int) {
        self.type = .interval
        self.intervalSeconds = max(1, intervalSeconds)
        self.subsystem = nil
        self.eventName = nil
    }

    /// Creates a diagnostics-event trigger.
    /// - Parameters:
    ///   - subsystem: Event subsystem.
    ///   - eventName: Event name.
    public init(diagnosticEventSubsystem subsystem: String, eventName: String) {
        self.type = .diagnosticEvent
        self.intervalSeconds = nil
        self.subsystem = subsystem.trimmingCharacters(in: .whitespacesAndNewlines)
        self.eventName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Persisted proactive automation rule definition.
public struct AutomationRule: Codable, Sendable, Equatable, Identifiable {
    /// Stable rule identifier.
    public let id: String
    /// Human-readable rule name.
    public let name: String
    /// Whether the rule is active.
    public let enabled: Bool
    /// Session key used for proactive run execution.
    public let sessionKey: String
    /// Prompt payload dispatched when the rule fires.
    public let prompt: String
    /// Optional model-provider override.
    public let modelProviderID: String?
    /// Trigger configuration.
    public let trigger: AutomationTrigger
    /// Last execution timestamp for recurrence control.
    public let lastExecutedAt: Date?

    /// Creates an automation rule.
    /// - Parameters:
    ///   - id: Optional stable identifier.
    ///   - name: Rule name.
    ///   - enabled: Whether the rule is active.
    ///   - sessionKey: Session key for proactive run execution.
    ///   - prompt: Prompt payload.
    ///   - modelProviderID: Optional model-provider override.
    ///   - trigger: Trigger configuration.
    ///   - lastExecutedAt: Last execution timestamp.
    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        sessionKey: String,
        prompt: String,
        modelProviderID: String? = nil,
        trigger: AutomationTrigger,
        lastExecutedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sessionKey = sessionKey
        self.prompt = prompt
        self.modelProviderID = modelProviderID
        self.trigger = trigger
        self.lastExecutedAt = lastExecutedAt
    }

    /// Returns a copy with a new execution timestamp.
    /// - Parameter date: Execution timestamp.
    /// - Returns: Updated rule.
    public func withLastExecuted(at date: Date) -> AutomationRule {
        AutomationRule(
            id: self.id,
            name: self.name,
            enabled: self.enabled,
            sessionKey: self.sessionKey,
            prompt: self.prompt,
            modelProviderID: self.modelProviderID,
            trigger: self.trigger,
            lastExecutedAt: date
        )
    }
}

/// Persistent store for proactive automation rules.
public actor AutomationRuleStore {
    private let fileURL: URL
    private var rulesByID: [String: AutomationRule] = [:]
    private var hasLoaded = false

    /// Creates an automation rule store.
    /// - Parameter fileURL: Optional custom storage path.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openclaw-automation-rules.json")
        }
    }

    /// Loads rules from disk.
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            self.rulesByID = [:]
            self.hasLoaded = true
            return
        }
        let payload = try Data(contentsOf: self.fileURL)
        let decoded = try JSONDecoder().decode([AutomationRule].self, from: payload)
        self.rulesByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        self.hasLoaded = true
    }

    /// Saves rules to disk.
    public func save() async throws {
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sortedRules = self.allRules()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(sortedRules)
        try payload.write(to: self.fileURL, options: [.atomic])
    }

    /// Returns all rules in deterministic order.
    public func allRules() -> [AutomationRule] {
        self.rulesByID.values.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.id < rhs.id
            }
            return lhs.name < rhs.name
        }
    }

    /// Upserts one rule.
    /// - Parameter rule: Rule to insert or replace.
    public func upsert(_ rule: AutomationRule) async {
        await self.ensureLoadedIfNeeded()
        self.rulesByID[rule.id] = rule
    }

    /// Removes one rule by identifier.
    /// - Parameter ruleID: Rule identifier.
    public func remove(ruleID: String) async {
        await self.ensureLoadedIfNeeded()
        self.rulesByID.removeValue(forKey: ruleID)
    }

    /// Returns rules due for execution.
    /// - Parameters:
    ///   - date: Current timestamp.
    ///   - event: Optional diagnostics event used for event-trigger evaluation.
    /// - Returns: Due rules.
    public func dueRules(
        at date: Date = Date(),
        matching event: RuntimeDiagnosticEvent? = nil
    ) async -> [AutomationRule] {
        await self.ensureLoadedIfNeeded()
        return self.allRules().filter { rule in
            guard rule.enabled else {
                return false
            }
            switch rule.trigger.type {
            case .interval:
                guard let seconds = rule.trigger.intervalSeconds, seconds > 0 else {
                    return false
                }
                guard let last = rule.lastExecutedAt else {
                    return true
                }
                return date.timeIntervalSince(last) >= TimeInterval(seconds)
            case .diagnosticEvent:
                guard let event else {
                    return false
                }
                let subsystem = rule.trigger.subsystem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let eventName = rule.trigger.eventName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return subsystem == event.subsystem && eventName == event.name
            }
        }
    }

    /// Marks rule attempts for recurrence control.
    /// - Parameters:
    ///   - ruleIDs: Attempted rule identifiers.
    ///   - date: Attempt timestamp.
    public func markAttempted(ruleIDs: [String], at date: Date = Date()) async {
        await self.ensureLoadedIfNeeded()
        let uniqueIDs = Set(ruleIDs)
        for id in uniqueIDs {
            guard let rule = self.rulesByID[id] else {
                continue
            }
            self.rulesByID[id] = rule.withLastExecuted(at: date)
        }
    }

    private func ensureLoadedIfNeeded() async {
        guard !self.hasLoaded else {
            return
        }
        try? await self.load()
    }
}
