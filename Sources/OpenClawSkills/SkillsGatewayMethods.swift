import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Native (non-skill) chat command advertised by `commands.list`.
public struct SkillNativeCommand: Sendable, Equatable {
    /// Command name without `/`.
    public let name: String
    /// Description.
    public let description: String
    /// Category (`session`, `options`, …).
    public let category: String
    /// Whether the command takes arguments.
    public let acceptsArgs: Bool
    /// Argument definitions in the upstream `CommandEntry.args` shape.
    public let args: [[String: AnyCodable]]

    /// Creates a native command.
    /// - Parameters:
    ///   - name: Name.
    ///   - description: Description.
    ///   - category: Category.
    ///   - acceptsArgs: Accepts arguments.
    ///   - args: Argument definitions.
    public init(name: String, description: String, category: String, acceptsArgs: Bool = false, args: [[String: AnyCodable]] = []) {
        self.name = name
        self.description = description
        self.category = category
        self.acceptsArgs = acceptsArgs
        self.args = args
    }

    /// Commands the embedded runtime implements: `reset`, `compact`, `think`, `verbose`.
    public static let defaults: [SkillNativeCommand] = [
        SkillNativeCommand(name: "reset", description: "Start a new session.", category: "session"),
        SkillNativeCommand(name: "compact", description: "Compact the session transcript.", category: "session"),
        SkillNativeCommand(
            name: "think",
            description: "Set the thinking level.",
            category: "options",
            acceptsArgs: true,
            args: [[
                "name": AnyCodable("level"),
                "description": AnyCodable("Thinking level"),
                "type": AnyCodable("string"),
                "choices": AnyCodable(["off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra"].map {
                    AnyCodable(["value": AnyCodable($0), "label": AnyCodable($0)])
                }),
            ]]
        ),
        SkillNativeCommand(
            name: "verbose",
            description: "Toggle verbose tool output.",
            category: "options",
            acceptsArgs: true,
            args: [[
                "name": AnyCodable("mode"),
                "description": AnyCodable("on or off"),
                "type": AnyCodable("string"),
                "choices": AnyCodable(["on", "off"].map { AnyCodable(["value": AnyCodable($0), "label": AnyCodable($0)]) }),
            ]]
        ),
    ]
}

/// Wiring for the in-process `skills.status`, `skills.bins`, `commands.list` (and, with a ClawHub
/// client, `skills.search` / `skills.detail`) gateway methods.
public struct SkillsGatewayConfiguration: Sendable {
    /// Registry the handlers read.
    public var registry: SkillRegistry
    /// Resolves the eligibility context (config, environment, agent skill filter) for an agent.
    public var contextProvider: @Sendable (_ agentID: String?) async -> SkillEligibilityContext
    /// Known agent identifiers; an unknown `agentId` is `INVALID_REQUEST` (`nil` accepts any).
    public var knownAgentIDs: Set<String>?
    /// Native commands listed before skill commands.
    public var nativeCommands: [SkillNativeCommand]
    /// Registry client for `skills.search` / `skills.detail` (not registered when `nil`).
    public var clawHub: ClawHubClient?

    /// Creates the configuration.
    /// - Parameters:
    ///   - registry: Skill registry.
    ///   - contextProvider: Context resolver (defaults to the current host with no agent filter).
    ///   - knownAgentIDs: Known agents.
    ///   - nativeCommands: Native commands.
    ///   - clawHub: ClawHub client.
    public init(
        registry: SkillRegistry,
        contextProvider: @escaping @Sendable (_ agentID: String?) async -> SkillEligibilityContext = { _ in SkillEligibilityContext() },
        knownAgentIDs: Set<String>? = nil,
        nativeCommands: [SkillNativeCommand] = SkillNativeCommand.defaults,
        clawHub: ClawHubClient? = nil
    ) {
        self.registry = registry
        self.contextProvider = contextProvider
        self.knownAgentIDs = knownAgentIDs
        self.nativeCommands = nativeCommands
        self.clawHub = clawHub
    }
}

/// Upstream `COMMAND_LIST_MAX_ITEMS`.
let commandListMaxItems = 500

/// Registers the skill gateway methods on a server (or any registrar).
///
/// - `skills.status {agentId?, sessionKey?}` → ``SkillStatusReport``
/// - `skills.bins {}` → `{bins}` (node-scoped upstream: callers need the node role)
/// - `commands.list {sessionKey?, agentId?, provider?, scope?, includeArgs?}` → `{commands}` (max 500)
/// - `skills.search {query?, limit?}` / `skills.detail {slug}` when ``SkillsGatewayConfiguration/clawHub`` is set
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - configuration: Handler wiring.
public func registerSkillsGatewayMethods(
    on registrar: some GatewayMethodRegistrar,
    configuration: SkillsGatewayConfiguration
) async {
    await registrar.register(method: "skills.status") { request in
        let params = try request.decodeParams(SkillsStatusParams.self)
        let agentID = try SkillsGatewayHandlers.validateAgentID(params.agentid, configuration: configuration)
        let context = await configuration.contextProvider(agentID)
        let report = try await configuration.registry.statusReport(agentID: agentID, context: context)
        return try GatewayPayloadCodec.encode(report)
    }
    await registrar.register(method: "skills.bins") { _ in
        let bins = try await configuration.registry.requiredBins()
        return try GatewayPayloadCodec.encode(SkillsBinsResult(bins: bins))
    }
    await registrar.register(method: "commands.list") { request in
        let params = try request.decodeParams(CommandsListParams.self)
        let agentID = try SkillsGatewayHandlers.validateAgentID(params.agentid, configuration: configuration)
        let context = await configuration.contextProvider(agentID)
        let commands = try await SkillsGatewayHandlers.commandEntries(
            registry: configuration.registry,
            context: context,
            nativeCommands: configuration.nativeCommands,
            scope: params.scope?.stringValue,
            includeArgs: params.includeargs ?? true
        )
        return try GatewayPayloadCodec.encode(CommandsListResult(commands: commands))
    }
    if let clawHub = configuration.clawHub {
        await registerClawHubGatewayMethods(on: registrar, client: clawHub)
    }
}

/// Emits `skills.changed {reason}` through `emitter` whenever the registry reloads.
/// - Parameters:
///   - registry: Skill registry.
///   - emitter: Event emitter (for example `GatewayEventEmitter { await server.broadcast(event: $0, payload: $1) }`).
///   - reason: Reason string.
public func installSkillsChangedEvents(on registry: SkillRegistry, emitter: GatewayEventEmitter, reason: String = "reload") async {
    await registry.onChange { _ in
        await emitter.emit(.skillsChanged, payload: AnyCodable(["reason": AnyCodable(reason)]))
    }
}

enum SkillsGatewayHandlers {
    static func validateAgentID(_ raw: String?, configuration: SkillsGatewayConfiguration) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatewayMethodError.invalidRequest("unknown agentId")
        }
        if let known = configuration.knownAgentIDs, !known.contains(trimmed) {
            throw GatewayMethodError.invalidRequest("unknown agentId")
        }
        return trimmed
    }

    static func commandEntries(
        registry: SkillRegistry,
        context: SkillEligibilityContext,
        nativeCommands: [SkillNativeCommand],
        scope: String?,
        includeArgs: Bool
    ) async throws -> [CommandEntry] {
        let scopeFilter = (scope ?? "both").lowercased()
        var entries: [CommandEntry] = []
        for command in nativeCommands {
            entries.append(
                CommandEntry(
                    name: command.name,
                    nativename: scopeFilter == "text" ? nil : command.name,
                    textaliases: scopeFilter == "native" ? nil : ["/\(command.name)"],
                    description: String(command.description.prefix(2_000)),
                    category: AnyCodable(command.category),
                    source: AnyCodable("native"),
                    scope: AnyCodable("both"),
                    acceptsargs: command.acceptsArgs,
                    args: includeArgs && command.acceptsArgs && !command.args.isEmpty ? command.args : nil
                )
            )
        }
        let specs = try await registry.commandSpecs(reservedNames: nativeCommands.map(\.name), context: context)
        for spec in specs {
            entries.append(
                CommandEntry(
                    name: spec.name,
                    nativename: scopeFilter == "text" ? nil : spec.name,
                    textaliases: scopeFilter == "native" ? nil : ["/\(spec.name)"],
                    description: String(spec.description.prefix(2_000)),
                    source: AnyCodable("skill"),
                    skilldisplayname: spec.displayName,
                    skillmodelvisible: spec.modelVisible,
                    scope: AnyCodable("both"),
                    acceptsargs: true
                )
            )
        }
        return Array(entries.prefix(commandListMaxItems))
    }
}
