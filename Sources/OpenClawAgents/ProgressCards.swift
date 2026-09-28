import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

// Durable session progress cards (upstream `packages/gateway-protocol/src/schema/progress-card.ts`):
// `progress_card` tool, `progressCard.get/put/refresh` RPCs and `progressCard.changed` events.

/// One plan step of a progress card.
public struct AgentProgressStep: Codable, Sendable, Equatable {
    /// Step text (≤ 512 UTF-8 bytes).
    public var step: String
    /// `pending`, `in_progress` or `completed`.
    public var status: String

    /// Creates a step.
    public init(step: String, status: String) {
        self.step = step
        self.status = status
    }
}

/// Session progress card (upstream `ProgressCard`).
public struct AgentProgressCard: Codable, Sendable, Equatable {
    /// Session key.
    public var sessionKey: String
    /// Revision (from 1).
    public var revision: Int
    /// Update time (ms).
    public var updatedAt: Int64
    /// Markdown body (≤ 8192 UTF-8 bytes).
    public var markdown: String?
    /// Plan steps (≤ 50).
    public var steps: [AgentProgressStep]?
}

/// Error raised by ``ProgressCardStore``.
public enum ProgressCardError: Error, LocalizedError, Sendable, Equatable {
    /// Invalid card content.
    case invalid(String)
    /// `expectedRevision` did not match.
    case revisionConflict(expected: Int, actual: Int)

    /// Human-readable message.
    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        case .revisionConflict(let expected, let actual):
            return "progress card revision changed (expected \(expected), found \(actual))"
        }
    }
}

/// Actor holding one progress card per session.
public actor ProgressCardStore {
    /// Maximum markdown size.
    public static let maxMarkdownBytes = 8_192
    /// Maximum plan steps.
    public static let maxSteps = 50
    /// Maximum step size.
    public static let maxStepBytes = 512
    private static let stepStatuses: Set<String> = ["pending", "in_progress", "completed"]

    private var cards: [String: AgentProgressCard] = [:]
    private var listeners: [@Sendable (AgentProgressCard?, String) async -> Void] = []

    /// Creates an empty store.
    public init() {}

    /// Adds a change listener (`progressCard.changed`).
    /// - Parameter listener: Listener receiving the card (or `nil` when cleared) and the session key.
    public func addListener(_ listener: @escaping @Sendable (AgentProgressCard?, String) async -> Void) {
        self.listeners.append(listener)
    }

    /// Returns a session's card.
    /// - Parameter sessionKey: Session key.
    /// - Returns: The card.
    public func card(sessionKey: String) -> AgentProgressCard? {
        self.cards[sessionKey]
    }

    /// Replaces a session's card.
    /// - Parameters:
    ///   - sessionKey: Session key.
    ///   - markdown: Markdown body.
    ///   - steps: Plan steps.
    ///   - expectedRevision: Optional optimistic-concurrency revision.
    /// - Returns: The stored card.
    /// - Throws: ``ProgressCardError``.
    @discardableResult
    public func put(sessionKey: String, markdown: String?, steps: [AgentProgressStep]?, expectedRevision: Int? = nil) throws -> AgentProgressCard {
        if let markdown, markdown.utf8.count > Self.maxMarkdownBytes {
            throw ProgressCardError.invalid("progress card markdown exceeds \(Self.maxMarkdownBytes) bytes")
        }
        if let steps {
            guard steps.count <= Self.maxSteps else {
                throw ProgressCardError.invalid("progress card allows at most \(Self.maxSteps) steps")
            }
            for step in steps {
                guard !step.step.isEmpty, step.step.utf8.count <= Self.maxStepBytes, Self.stepStatuses.contains(step.status) else {
                    throw ProgressCardError.invalid("progress card steps need 1-\(Self.maxStepBytes) bytes and status pending|in_progress|completed")
                }
            }
        }
        let current = self.cards[sessionKey]
        if let expectedRevision, expectedRevision != (current?.revision ?? 0) {
            throw ProgressCardError.revisionConflict(expected: expectedRevision, actual: current?.revision ?? 0)
        }
        let card = AgentProgressCard(
            sessionKey: sessionKey,
            revision: (current?.revision ?? 0) + 1,
            updatedAt: SessionTranscriptClock.nowMs(),
            markdown: markdown,
            steps: steps
        )
        self.cards[sessionKey] = card
        self.notify(card, sessionKey: sessionKey)
        return card
    }

    /// Removes a session's card.
    /// - Parameter sessionKey: Session key.
    public func clear(sessionKey: String) {
        guard self.cards.removeValue(forKey: sessionKey) != nil else { return }
        self.notify(nil, sessionKey: sessionKey)
    }

    private func notify(_ card: AgentProgressCard?, sessionKey: String) {
        let listeners = self.listeners
        guard !listeners.isEmpty else { return }
        Task {
            for listener in listeners {
                await listener(card, sessionKey)
            }
        }
    }

    /// `progress_card` tool bound to this store.
    nonisolated public var tool: any AgentTool {
        ProgressCardTool(store: self)
    }

    /// Registers `progressCard.get/put/refresh` and emits `progressCard.changed`.
    /// - Parameters:
    ///   - server: Gateway server.
    ///   - runtime: Runtime that serves refresh runs.
    public func attach(to server: GatewayServer, runtime: EmbeddedAgentRuntime) async {
        self.addListener { [weak server] card, sessionKey in
            await server?.broadcast(
                event: GatewayEventName.progressCardChanged.rawValue,
                payload: AnyCodable(["sessionKey": AnyCodable(sessionKey), "revision": AnyCodable(card?.revision)])
            )
        }
        await server.register(method: "progressCard.get", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("progress cards unavailable") }
            guard let sessionKey = request.stringParam("sessionKey") else {
                throw GatewayMethodError.invalidRequest("progressCard.get requires sessionKey")
            }
            return AnyCodable(["card": Self.payload(await self.card(sessionKey: sessionKey))])
        }
        await server.register(method: "progressCard.put", descriptor: nil) { [weak self] request in
            guard let self else { throw GatewayMethodError.unavailable("progress cards unavailable") }
            guard let sessionKey = request.stringParam("sessionKey") else {
                throw GatewayMethodError.invalidRequest("progressCard.put requires sessionKey")
            }
            let steps = request.params["plan"].flatMap { try? AgentJSONCoding.decode([AgentProgressStep].self, from: $0) }
            do {
                let card = try await self.put(
                    sessionKey: sessionKey,
                    markdown: request.params["markdown"]?.stringValue,
                    steps: steps,
                    expectedRevision: request.params["expectedRevision"]?.intValue
                )
                return AnyCodable(["card": Self.payload(card)])
            } catch let error as ProgressCardError {
                throw GatewayMethodError.invalidRequest(error.localizedDescription)
            }
        }
        await server.register(method: "progressCard.refresh", descriptor: nil) { [weak self, weak runtime] request in
            guard let self, let runtime else { throw GatewayMethodError.unavailable("progress cards unavailable") }
            guard let sessionKey = request.stringParam("sessionKey"), let key = request.stringParam("idempotencyKey") else {
                throw GatewayMethodError.invalidRequest("progressCard.refresh requires sessionKey and idempotencyKey")
            }
            let runID = await runtime.start(
                AgentRunRequest(
                    runID: "progress-\(key)",
                    sessionKey: sessionKey,
                    prompt: "Refresh the session progress card with the progress_card tool to reflect the current status. Do not reply to the user.",
                    hiddenPrompt: true
                ),
                streaming: true
            )
            return AnyCodable([
                "runId": AnyCodable(runID),
                "status": AnyCodable("accepted"),
                "revision": AnyCodable(await self.card(sessionKey: sessionKey)?.revision ?? 1),
            ])
        }
    }

    static func payload(_ card: AgentProgressCard?) -> AnyCodable {
        guard let card else { return .nullValue }
        return (try? AnyCodable(encoding: card)) ?? .nullValue
    }
}

/// `progress_card` tool: maintains the session progress card.
struct ProgressCardTool: AgentTool {
    let name = "progress_card"
    let store: ProgressCardStore

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: self.name,
            label: "Progress Card",
            description: "Maintain the session progress card: a short markdown status and/or a plan of steps "
                + "(status pending|in_progress|completed). Each call replaces the card.",
            parameters: [
                "type": AnyCodable("object"),
                "additionalProperties": AnyCodable(false),
                "properties": AnyCodable([
                    "markdown": AnyCodable(["type": AnyCodable("string")]),
                    "plan": AnyCodable([
                        "type": AnyCodable("array"),
                        "maxItems": AnyCodable(ProgressCardStore.maxSteps),
                        "items": AnyCodable([
                            "type": AnyCodable("object"),
                            "required": AnyCodable(["step", "status"]),
                            "properties": AnyCodable([
                                "step": AnyCodable(["type": AnyCodable("string"), "minLength": AnyCodable(1)]),
                                "status": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["pending", "in_progress", "completed"])]),
                            ]),
                        ]),
                    ]),
                ]),
            ],
            sectionID: "agents",
            defaultProfiles: [.coding],
            hideFromChannelProgress: true
        )
    }

    func invoke(_ invocation: AgentToolInvocation, update _: AgentToolUpdateHandler?) async throws -> AgentToolOutput {
        guard let sessionKey = invocation.sessionKey else { return .error("progress_card requires a session") }
        let steps = invocation.arguments["plan"].flatMap { try? AgentJSONCoding.decode([AgentProgressStep].self, from: $0) }
        do {
            let card = try await self.store.put(sessionKey: sessionKey, markdown: invocation.arguments["markdown"]?.stringValue, steps: steps)
            return .text("Progress card updated (revision \(card.revision)).", details: ProgressCardStore.payload(card))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
