import Foundation
import OpenClawCore
import OpenClawProtocol

// Structured operator questions (upstream `packages/gateway-protocol/src/schema/questions.ts`,
// `src/gateway/server-methods/question.ts`). Records use Int64 milliseconds; `payload` projects the
// upstream `QuestionRecord` wire shape.

/// One selectable option of an ``AgentQuestionPrompt``.
public struct AgentQuestionOption: Codable, Sendable, Equatable {
    /// Option label.
    public var label: String
    /// Optional description.
    public var description: String?

    /// Creates an option.
    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// One question shown to the operator (upstream `Question`).
public struct AgentQuestionPrompt: Codable, Sendable, Equatable {
    /// Answer key (`^[a-z][a-z0-9_]*$`).
    public var questionID: String
    /// Chip label (≤ 12 characters).
    public var header: String
    /// Question text.
    public var question: String
    /// Optional external page to open (separate from answering).
    public var url: String?
    /// Options (≤ 4).
    public var options: [AgentQuestionOption]
    /// Whether several options may be chosen.
    public var multiSelect: Bool?
    /// Whether free text is offered (always true for `ask_user`).
    public var isOther: Bool?
    /// Secret entry (credential-request cards); never set by `ask_user`.
    public var isSecret: Bool?

    /// Creates a prompt.
    public init(
        questionID: String,
        header: String,
        question: String,
        url: String? = nil,
        options: [AgentQuestionOption] = [],
        multiSelect: Bool? = nil,
        isOther: Bool? = nil,
        isSecret: Bool? = nil
    ) {
        self.questionID = questionID
        self.header = header
        self.question = question
        self.url = url
        self.options = options
        self.multiSelect = multiSelect
        self.isOther = isOther
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey {
        case questionID = "questionId"
        case header
        case question
        case url
        case options
        case multiSelect
        case isOther
        case isSecret
    }

    /// Whether a question id matches `^[a-z][a-z0-9_]*$`.
    /// - Parameter id: Candidate id.
    /// - Returns: `true` when valid.
    public static func isValidQuestionID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first, (97...122).contains(first.value) else { return false }
        return scalars.dropFirst().allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" }
    }
}

/// Lifecycle status of an ``AgentQuestion``.
public enum AgentQuestionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Waiting for an answer.
    case pending
    /// Answered.
    case answered
    /// Cancelled.
    case cancelled
    /// Expired without an answer.
    case expired
}

/// One question request held by ``QuestionBroker`` (upstream `QuestionRecord`).
public struct AgentQuestion: Codable, Sendable, Equatable {
    /// Request id.
    public var id: String
    /// Questions (1...3).
    public var questions: [AgentQuestionPrompt]
    /// Requesting agent.
    public var agentID: String?
    /// Raising session.
    public var sessionKey: String?
    /// Requesting run.
    public var runID: String?
    /// Creation time (ms).
    public var createdAtMs: Int64
    /// Expiry time (ms).
    public var expiresAtMs: Int64
    /// Status.
    public var status: AgentQuestionStatus
    /// Answers keyed by question id (answered only).
    public var answers: [String: [String]]?
    /// Who answered or cancelled.
    public var resolvedBy: String?
    /// Idempotency token of the answering surface.
    public var resolutionID: String?
    /// Resolution time (ms).
    public var resolvedAtMs: Int64?

    /// Upstream `QuestionRecord` JSON.
    public var payload: [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "id": AnyCodable(self.id),
            "questions": (try? AnyCodable(encoding: self.questions)) ?? AnyCodable([AnyCodable]()),
            "createdAtMs": AnyCodable(self.createdAtMs),
            "expiresAtMs": AnyCodable(self.expiresAtMs),
            "status": AnyCodable(self.status.rawValue),
        ]
        if let agentID { payload["agentId"] = AnyCodable(agentID) }
        if let sessionKey { payload["sessionKey"] = AnyCodable(sessionKey) }
        if let runID { payload["runId"] = AnyCodable(runID) }
        if let answers, self.status == .answered {
            payload["answers"] = AnyCodable(["answers": Self.answersPayload(answers)])
        }
        if let resolvedBy { payload["resolvedBy"] = AnyCodable(resolvedBy) }
        return payload
    }

    /// Upstream `question.resolved` event payload.
    public var resolvedEventPayload: [String: AnyCodable] {
        var payload: [String: AnyCodable] = ["id": AnyCodable(self.id), "status": AnyCodable(self.status.rawValue)]
        if self.status == .answered {
            payload["answers"] = AnyCodable(["answers": Self.answersPayload(self.answers ?? [:])])
        }
        return payload
    }

    static func answersPayload(_ answers: [String: [String]]) -> AnyCodable {
        AnyCodable(answers.mapValues { AnyCodable($0.map { AnyCodable($0) }) })
    }
}

/// Outcome of ``QuestionBroker/waitAnswer(id:timeoutMs:)`` (upstream `QuestionWaitAnswerResult`).
public enum AgentQuestionWaitResult: Sendable, Equatable {
    /// Still pending when the wait bound elapsed.
    case pending
    /// Answered.
    case answered(answers: [String: [String]], resolutionID: String?)
    /// Cancelled.
    case cancelled
    /// Expired.
    case expired

    /// Upstream wire payload (`resolutionId` only when requested).
    /// - Parameter includeResolutionID: Whether to include the resolution id.
    /// - Returns: The payload.
    public func payload(includeResolutionID: Bool = false) -> [String: AnyCodable] {
        switch self {
        case .pending:
            return ["status": AnyCodable("pending")]
        case .answered(let answers, let resolutionID):
            var payload: [String: AnyCodable] = [
                "status": AnyCodable("answered"),
                "answers": AnyCodable(["answers": AgentQuestion.answersPayload(answers)]),
            ]
            if includeResolutionID, let resolutionID {
                payload["resolutionId"] = AnyCodable(resolutionID)
            }
            return payload
        case .cancelled:
            return ["status": AnyCodable("cancelled")]
        case .expired:
            return ["status": AnyCodable("expired")]
        }
    }
}

/// Error raised by ``QuestionBroker``.
public enum QuestionBrokerError: Error, LocalizedError, Sendable, Equatable {
    /// Unknown question id.
    case notFound(String)
    /// The question is no longer pending.
    case notPending(String, AgentQuestionStatus)
    /// The request shape is invalid.
    case invalid(String)
    /// The feature is not available in the embedded runtime (for example secret-store bindings).
    case unavailable(String)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "unknown question id: \(id)"
        case .notPending(let id, let status):
            return "question \(id) is already \(status.rawValue)"
        case .invalid(let message), .unavailable(let message):
            return message
        }
    }
}

/// Actor that owns transient operator questions.
///
/// Answers go to the first resolver; resolved records stay queryable for ten minutes. Streams and
/// listeners observe `requested`/`resolved` transitions for gateway events and native UIs.
public actor QuestionBroker {
    /// Retention of resolved records (10 minutes).
    public static let resolvedRetentionMs: Int64 = 600_000
    /// Default request timeout (15 minutes).
    public static let defaultTimeoutMs: Int64 = 900_000

    /// Change notification.
    public typealias Listener = @Sendable (AgentQuestion) async -> Void

    private var questions: [String: AgentQuestion] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<AgentQuestion?, Never>]] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<AgentQuestion>.Continuation] = [:]
    private var listeners: [Listener] = []
    private let clock: @Sendable () -> Int64

    /// Creates a broker.
    /// - Parameter clock: Millisecond clock.
    public init(clock: @escaping @Sendable () -> Int64 = { SessionTranscriptClock.nowMs() }) {
        self.clock = clock
    }

    /// Stream of question changes.
    /// - Parameter limit: Buffered updates per subscriber.
    /// - Returns: The stream.
    public func updates(bufferingNewest limit: Int = 128) -> AsyncStream<AgentQuestion> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentQuestion>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
        self.subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Adds a listener invoked for every change.
    /// - Parameter listener: Listener.
    public func addListener(_ listener: @escaping Listener) {
        self.listeners.append(listener)
    }

    private func removeSubscriber(_ id: UUID) {
        self.subscribers[id] = nil
    }

    private func publish(_ question: AgentQuestion) {
        for continuation in self.subscribers.values {
            continuation.yield(question)
        }
        let listeners = self.listeners
        guard !listeners.isEmpty else { return }
        Task {
            for listener in listeners {
                await listener(question)
            }
        }
    }

    /// Creates a pending question request.
    /// - Parameters:
    ///   - id: Optional explicit id.
    ///   - questions: Questions (1...3).
    ///   - agentID: Requesting agent.
    ///   - sessionKey: Raising session.
    ///   - runID: Requesting run.
    ///   - timeoutMs: Deadline (default 15 minutes).
    /// - Returns: The pending record.
    /// - Throws: ``QuestionBrokerError/invalid(_:)`` for malformed requests.
    @discardableResult
    public func request(
        id: String? = nil,
        questions: [AgentQuestionPrompt],
        agentID: String? = nil,
        sessionKey: String? = nil,
        runID: String? = nil,
        timeoutMs: Int64? = nil
    ) throws -> AgentQuestion {
        try Self.validate(questions)
        self.pruneResolved()
        let requestID = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? UUID().uuidString.lowercased()
        if let existing = self.questions[requestID] {
            return existing
        }
        let now = self.clock()
        let timeout = max(1, timeoutMs ?? Self.defaultTimeoutMs)
        let record = AgentQuestion(
            id: requestID,
            questions: questions,
            agentID: agentID,
            sessionKey: sessionKey,
            runID: runID,
            createdAtMs: now,
            expiresAtMs: now + timeout,
            status: .pending
        )
        self.questions[requestID] = record
        self.expiryTasks[requestID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
            await self?.expire(requestID)
        }
        self.publish(record)
        return record
    }

    /// Waits for an answer.
    /// - Parameters:
    ///   - id: Question id.
    ///   - timeoutMs: Optional wait bound (returns `.pending` when it elapses first).
    /// - Returns: The outcome.
    /// - Throws: ``QuestionBrokerError/notFound(_:)``.
    public func waitAnswer(id: String, timeoutMs: Int64? = nil) async throws -> AgentQuestionWaitResult {
        guard let record = self.questions[id] else {
            throw QuestionBrokerError.notFound(id)
        }
        if record.status != .pending {
            return Self.result(for: record)
        }
        guard let resolved = await self.awaitResolution(id, timeoutMs: timeoutMs) else {
            return .pending
        }
        return Self.result(for: resolved)
    }

    /// Suspends until the question resolves, or returns `nil` once `timeoutMs` elapses.
    private func awaitResolution(_ id: String, timeoutMs: Int64?) async -> AgentQuestion? {
        if let record = self.questions[id], record.status != .pending {
            return record
        }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            self.waiters[id, default: [:]][token] = continuation
            if let timeoutMs {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                    self.expireWaiter(id, token: token)
                }
            }
        }
    }

    private func expireWaiter(_ id: String, token: UUID) {
        guard let continuation = self.waiters[id]?.removeValue(forKey: token) else { return }
        if self.waiters[id]?.isEmpty == true {
            self.waiters[id] = nil
        }
        continuation.resume(returning: nil)
    }

    /// Answers a pending question.
    /// - Parameters:
    ///   - id: Question id.
    ///   - answers: Answers keyed by question id.
    ///   - resolvedBy: Answering surface.
    ///   - resolutionID: Idempotency token; a repeat with the same token returns the recorded answer.
    /// - Returns: The answered record.
    /// - Throws: ``QuestionBrokerError``.
    @discardableResult
    public func resolve(
        id: String,
        answers: [String: [String]],
        resolvedBy: String? = nil,
        resolutionID: String? = nil
    ) throws -> AgentQuestion {
        guard var record = self.questions[id] else {
            throw QuestionBrokerError.notFound(id)
        }
        guard record.status == .pending else {
            if record.status == .answered, let resolutionID, resolutionID == record.resolutionID {
                return record
            }
            throw QuestionBrokerError.notPending(id, record.status)
        }
        let known = Set(record.questions.map(\.questionID))
        if let unknown = answers.keys.first(where: { !known.contains($0) }) {
            throw QuestionBrokerError.invalid("answer for unknown question id: \(unknown)")
        }
        record.status = .answered
        record.answers = answers
        record.resolvedBy = resolvedBy
        record.resolutionID = resolutionID
        record.resolvedAtMs = self.clock()
        self.finish(record)
        return record
    }

    /// Cancels a pending question.
    /// - Parameters:
    ///   - id: Question id.
    ///   - resolvedBy: Cancelling surface.
    /// - Returns: The cancelled record.
    /// - Throws: ``QuestionBrokerError``.
    @discardableResult
    public func cancel(id: String, resolvedBy: String? = nil) throws -> AgentQuestion {
        guard var record = self.questions[id] else {
            throw QuestionBrokerError.notFound(id)
        }
        guard record.status == .pending else {
            throw QuestionBrokerError.notPending(id, record.status)
        }
        record.status = .cancelled
        record.resolvedBy = resolvedBy
        record.resolvedAtMs = self.clock()
        self.finish(record)
        return record
    }

    /// Cancels every pending question of a run (the requesting run closed).
    /// - Parameter runID: Run identifier.
    /// - Returns: Number of cancelled questions.
    @discardableResult
    public func cancel(runID: String) -> Int {
        let ids = self.questions.values.filter { $0.status == .pending && $0.runID == runID }.map(\.id)
        for id in ids {
            _ = try? self.cancel(id: id, resolvedBy: "runtime")
        }
        return ids.count
    }

    /// Returns a record (pending or recently resolved).
    /// - Parameter id: Question id.
    /// - Returns: The record, if known.
    public func get(id: String) -> AgentQuestion? {
        self.pruneResolved()
        return self.questions[id]
    }

    /// Pending and recently resolved records, oldest first.
    /// - Returns: Records.
    public func list() -> [AgentQuestion] {
        self.pruneResolved()
        return self.questions.values.sorted { $0.createdAtMs == $1.createdAtMs ? $0.id < $1.id : $0.createdAtMs < $1.createdAtMs }
    }

    /// Pending question of a session, if any.
    /// - Parameter sessionKey: Session key.
    /// - Returns: The pending record.
    public func pendingQuestion(sessionKey: String) -> AgentQuestion? {
        self.questions.values.first { $0.status == .pending && $0.sessionKey == sessionKey }
    }

    private func expire(_ id: String) {
        guard var record = self.questions[id], record.status == .pending else { return }
        record.status = .expired
        record.resolvedAtMs = self.clock()
        self.finish(record)
    }

    private func finish(_ record: AgentQuestion) {
        self.questions[record.id] = record
        self.expiryTasks.removeValue(forKey: record.id)?.cancel()
        for waiter in (self.waiters.removeValue(forKey: record.id) ?? [:]).values {
            waiter.resume(returning: record)
        }
        self.publish(record)
    }

    private func pruneResolved() {
        let cutoff = self.clock() - Self.resolvedRetentionMs
        for (id, record) in self.questions where record.status != .pending && (record.resolvedAtMs ?? record.createdAtMs) < cutoff {
            self.questions[id] = nil
        }
    }

    private static func result(for record: AgentQuestion) -> AgentQuestionWaitResult {
        switch record.status {
        case .pending:
            return .pending
        case .answered:
            return .answered(answers: record.answers ?? [:], resolutionID: record.resolutionID)
        case .cancelled:
            return .cancelled
        case .expired:
            return .expired
        }
    }

    /// Validates a question request (upstream `questionShapeError`, embedded subset).
    /// - Parameter questions: Questions.
    /// - Throws: ``QuestionBrokerError/invalid(_:)``.
    public static func validate(_ questions: [AgentQuestionPrompt]) throws {
        guard (1...3).contains(questions.count) else {
            throw QuestionBrokerError.invalid("questions must contain 1-3 entries")
        }
        var seen: Set<String> = []
        for question in questions {
            guard AgentQuestionPrompt.isValidQuestionID(question.questionID) else {
                throw QuestionBrokerError.invalid("question id must match ^[a-z][a-z0-9_]*$: \(question.questionID)")
            }
            guard seen.insert(question.questionID).inserted else {
                throw QuestionBrokerError.invalid("duplicate question id: \(question.questionID)")
            }
            guard question.header.count <= 12 else {
                throw QuestionBrokerError.invalid("question header exceeds 12 characters: \(question.questionID)")
            }
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuestionBrokerError.invalid("question text must not be empty: \(question.questionID)")
            }
            guard question.options.count <= 4, question.options.allSatisfy({ !$0.label.isEmpty }) else {
                throw QuestionBrokerError.invalid("questions allow at most 4 non-empty options: \(question.questionID)")
            }
        }
    }
}
