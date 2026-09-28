import Foundation
import OpenClawCore
import OpenClawProtocol

/// Built-in `ask_user` tool (upstream `src/agents/tools/ask-user-tool.ts`): asks the human 1–3
/// structured questions through a ``QuestionBroker`` and waits for the answer.
///
/// - Options: 2–4 per question; free text ("Other") is always offered, so authored "Other" options
///   are unnecessary. Credential-style (`isSecret`) questions are not exposed.
/// - `timeoutSeconds` defaults to 900 and is clamped to `30...3600`.
/// - A session holds at most one pending `ask_user` question.
/// - Answered results carry `details: {status: "answered", answers: {answers: {<id>: [String]}}}`;
///   cancelled or expired questions return a non-error `no_answer` result.
public struct AskUserTool: AgentTool {
    /// Tool name.
    public static let toolName = "ask_user"
    /// Default human wait (seconds).
    public static let defaultTimeoutSeconds = 900
    /// Error returned when the session already waits on a question.
    public static let pendingQuestionMessage =
        "ask_user already has a pending question for this session; wait for it to resolve before asking another"

    /// Tool name.
    public let name = AskUserTool.toolName
    private let broker: QuestionBroker

    /// Creates the tool.
    /// - Parameter broker: Question broker answering the prompts.
    public init(broker: QuestionBroker) {
        self.broker = broker
    }

    /// Model-facing description (upstream `describeAskUserTool`).
    public var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Ask User",
            description: [
                "Ask the human user 1-3 structured questions and wait for their answer; "
                    + "`multiSelect` allows picking several options and `timeoutSeconds` bounds the wait.",
                "Use only when blocked on a decision genuinely theirs that cannot be resolved from the request, code, "
                    + "or sensible defaults; never ask whether to proceed or confirm a plan.",
                "Ask exactly one question per call unless several answers must be submitted together; "
                    + "one single-select question uses native controls on supported messaging channels.",
                "Put every selectable choice in `options`, never only in the question text. "
                    + "Put the recommended option first and suffix its label with ` (Recommended)`.",
                "Use `multiSelect` only when the user may choose several options at once; otherwise omit it.",
                "Do not include an Other option; free text is added automatically.",
                "If the result is no_answer, continue with best judgment.",
            ].joined(separator: " "),
            displaySummary: "Ask the user and wait for an answer.",
            parameters: Self.parametersSchema,
            source: .core,
            sectionID: "agents",
            defaultProfiles: [.coding, .messaging],
            risk: .low,
            executionMode: .sequential,
            catalogMode: .directOnly
        )
    }

    /// JSON Schema of the arguments (upstream `AskUserToolSchema`).
    public static let parametersSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "additionalProperties": AnyCodable(false),
        "required": AnyCodable(["questions"]),
        "properties": AnyCodable([
            "questions": AnyCodable([
                "type": AnyCodable("array"),
                "minItems": AnyCodable(1),
                "maxItems": AnyCodable(3),
                "items": AnyCodable([
                    "type": AnyCodable("object"),
                    "additionalProperties": AnyCodable(false),
                    "required": AnyCodable(["id", "header", "question", "options"]),
                    "properties": AnyCodable([
                        "id": AnyCodable([
                            "type": AnyCodable("string"),
                            "pattern": AnyCodable("^[a-z][a-z0-9_]*$"),
                            "description": AnyCodable("Unique snake_case answer key."),
                        ]),
                        "header": AnyCodable([
                            "type": AnyCodable("string"),
                            "minLength": AnyCodable(1),
                            "description": AnyCodable("Short chip label; longer input is truncated to 12 characters."),
                        ]),
                        "question": AnyCodable([
                            "type": AnyCodable("string"),
                            "minLength": AnyCodable(1),
                            "description": AnyCodable("Single-sentence question only. Put all selectable choices in options."),
                        ]),
                        "options": AnyCodable([
                            "type": AnyCodable("array"),
                            "minItems": AnyCodable(2),
                            "maxItems": AnyCodable(4),
                            "description": AnyCodable(
                                "Every selectable choice. Put the recommended choice first; do not repeat choices only in the question text."
                            ),
                            "items": AnyCodable([
                                "type": AnyCodable("object"),
                                "additionalProperties": AnyCodable(false),
                                "required": AnyCodable(["label"]),
                                "properties": AnyCodable([
                                    "label": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)]),
                                    "description": AnyCodable(["type": AnyCodable("string")]),
                                ]),
                            ]),
                        ]),
                        "multiSelect": AnyCodable([
                            "type": AnyCodable("boolean"),
                            "description": AnyCodable("True only when the user may choose several options at once."),
                        ]),
                    ]),
                ]),
            ]),
            "timeoutSeconds": AnyCodable([
                "type": AnyCodable("integer"),
                "description": AnyCodable(
                    "Maximum human wait in seconds; default 900, clamped 30-3600. Earlier run cancellation or overall run timeout still applies."
                ),
            ]),
        ]),
    ]

    /// Normalized arguments.
    public struct Normalized: Sendable, Equatable {
        /// Canonical questions.
        public let questions: [AgentQuestionPrompt]
        /// Clamped wait in seconds.
        public let timeoutSeconds: Int
    }

    /// Validates and canonicalizes model-authored arguments (upstream `normalizeAskUserParams`).
    /// - Parameter arguments: Tool arguments.
    /// - Returns: Normalized questions and timeout.
    /// - Throws: ``QuestionBrokerError/invalid(_:)``.
    public static func normalize(_ arguments: [String: AnyCodable]) throws -> Normalized {
        do {
            try JSONSchemaValidator.validate(arguments: arguments, against: Self.parametersSchema)
        } catch {
            throw QuestionBrokerError.invalid("ask_user arguments do not match the model-facing question contract: \(error.localizedDescription)")
        }
        let rawQuestions = arguments["questions"]?.arrayValue ?? []
        let questions = rawQuestions.compactMap(\.dictionaryValue).map { raw -> AgentQuestionPrompt in
            let options = (raw["options"]?.arrayValue ?? []).compactMap(\.dictionaryValue).map { option in
                AgentQuestionOption(
                    label: (option["label"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    description: option["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                )
            }
            return AgentQuestionPrompt(
                questionID: (raw["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                header: String((raw["header"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(12)),
                question: (raw["question"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                options: options,
                multiSelect: raw["multiSelect"]?.boolValue == true ? true : nil,
                isOther: true
            )
        }
        if questions.contains(where: { $0.header.isEmpty || $0.options.contains { $0.label.count > 64 } }) {
            throw QuestionBrokerError.invalid("ask_user questions exceed the model-facing display contract")
        }
        try QuestionBroker.validate(questions)
        return Normalized(questions: questions, timeoutSeconds: try Self.normalizeTimeoutSeconds(arguments["timeoutSeconds"]))
    }

    /// Clamps `timeoutSeconds` to `30...3600` (default 900).
    /// - Parameter raw: Raw value.
    /// - Returns: Seconds.
    /// - Throws: ``QuestionBrokerError/invalid(_:)`` for non-integers.
    public static func normalizeTimeoutSeconds(_ raw: AnyCodable?) throws -> Int {
        guard let raw, !raw.isNull else { return Self.defaultTimeoutSeconds }
        guard let seconds = raw.intValue else {
            throw QuestionBrokerError.invalid("timeoutSeconds must be an integer")
        }
        return min(3_600, max(30, seconds))
    }

    /// Asks the questions and waits.
    public func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        let normalized: Normalized
        do {
            normalized = try Self.normalize(invocation.arguments)
        } catch {
            return .error(error.localizedDescription)
        }
        if let sessionKey = invocation.sessionKey, await self.broker.pendingQuestion(sessionKey: sessionKey) != nil {
            return .error(Self.pendingQuestionMessage)
        }
        let record = try await self.broker.request(
            questions: normalized.questions,
            agentID: invocation.agentID,
            sessionKey: invocation.sessionKey,
            runID: invocation.runID,
            timeoutMs: Int64(normalized.timeoutSeconds) * 1_000
        )
        let outcome = try await withTaskCancellationHandler {
            try await self.broker.waitAnswer(id: record.id)
        } onCancel: {
            Task { _ = try? await self.broker.cancel(id: record.id, resolvedBy: "runtime") }
        }
        switch outcome {
        case .answered(let answers, _):
            let lines = normalized.questions.map { question in
                let values = answers[question.questionID] ?? []
                return "\(question.header): \(values.isEmpty ? "(no answer)" : values.joined(separator: ", "))"
            }
            let details: AnyCodable = AnyCodable([
                "status": AnyCodable("answered"),
                "answers": AnyCodable(["answers": AgentQuestion.answersPayload(answers)]),
            ])
            return AgentToolOutput(content: [.text("\(lines.joined(separator: "\n"))\n\n\(AgentToolOutput.renderText(details))")], details: details)
        case .cancelled, .expired, .pending:
            let note = outcome == .cancelled
                ? "The question was cancelled; proceed with best judgment."
                : "No answer arrived; proceed with best judgment."
            let details = AnyCodable(["status": AnyCodable("no_answer")])
            return AgentToolOutput(content: [.text("\(note)\n\n\(AgentToolOutput.renderText(details))")], details: details)
        }
    }
}
