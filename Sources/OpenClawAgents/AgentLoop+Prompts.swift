import Foundation
import OpenClawCore
import OpenClawMedia
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills

// Workspace prompts, skills, media and request building of the agent loop.

extension AgentLoop {
    // MARK: - Prompts

    struct WorkspacePrompt: Sendable {
        var bootstrap: String?
        var skills: String?
        var skillMode: SkillPromptMode?
    }

    /// Loads bootstrap context and skills; the v6 catalog is used when the model can call tools and a
    /// `read` tool is available (registering the jailed ``SkillReadTool`` when none is registered),
    /// otherwise skill bodies are inlined.
    func prepareWorkspace(
        request: AgentRunRequest,
        model: AgentRunModelContext,
        policy: ToolPolicy,
        session: SessionRecord?
    ) async throws -> WorkspacePrompt {
        guard let trimmed = request.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return WorkspacePrompt()
        }
        let root = URL(fileURLWithPath: trimmed)
        var skillsConfiguration = self.deps.configuration.skills ?? SkillsConfiguration()
        for (skill, enabled) in session?.toolOverrides?.skills ?? [:] where !enabled {
            var entry = skillsConfiguration.entries[skill] ?? SkillsConfiguration.Entry()
            entry.enabled = false
            skillsConfiguration.entries[skill] = entry
        }
        let registry = SkillRegistry(workspaceRoot: root, configuration: skillsConfiguration, diagnostics: self.deps.diagnostics)
        let toolCalling = model.usesContractV2 && model.capabilities.supportsTools
        let registeredRead = await self.deps.toolRegistry.tool(named: SkillReadTool.toolName) != nil
        let canOfferRead = policy.allows(SkillReadTool.toolName)
        let mode = self.deps.configuration.skillPromptMode ?? SkillPromptMode.resolve(
            supportsToolCalling: toolCalling,
            hasReadTool: canOfferRead && (registeredRead || self.deps.configuration.providesSkillReadTool)
        )
        let snapshot = try await registry.loadPromptSnapshot(
            options: SkillPromptOptions(mode: mode, contextTokenBudget: model.contextWindow)
        )
        let skills = snapshot.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .catalog, !skills.isEmpty, !registeredRead, self.deps.configuration.providesSkillReadTool {
            await self.deps.runTools.register(SkillReadTool(access: await registry.readAccess()))
        }
        let bootstrap = try await BootstrapContextLoader(workspaceRoot: root).loadPromptSnapshot().prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspacePrompt(
            bootstrap: bootstrap.isEmpty ? nil : bootstrap,
            skills: skills.isEmpty ? nil : skills,
            skillMode: skills.isEmpty ? nil : mode
        )
    }

    /// Registers per-run tools that depend on the run's inputs (`music_analyze` for audio attachments).
    func registerRunTools(attachments: [MediaAttachment]) async {
        guard let analyzer = self.deps.mediaServices.music,
              attachments.contains(where: { MediaPipeline.classify(mimeType: $0.mimeType) == .audio }),
              await self.deps.toolRegistry.tool(named: MusicAnalyzeTool.toolName) == nil
        else {
            return
        }
        await self.deps.runTools.register(MusicAnalyzeTool(attachments: attachments, analyzer: analyzer))
    }

    static func loadWorkspacePrompt(_ workspaceRootPath: String?) async throws -> WorkspacePrompt {
        guard let trimmed = workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return WorkspacePrompt()
        }
        let root = URL(fileURLWithPath: trimmed)
        let skills = try await SkillRegistry(workspaceRoot: root).loadPromptSnapshot().prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrap = try await BootstrapContextLoader(workspaceRoot: root).loadPromptSnapshot().prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspacePrompt(bootstrap: bootstrap.isEmpty ? nil : bootstrap, skills: skills.isEmpty ? nil : skills, skillMode: .inlineBodies)
    }

    /// Legacy single-message prompt (bootstrap, skills, attachments, `## User Request`) used for
    /// providers that predate contract v2; byte-identical to the 2026.2 composition when no media was
    /// converted.
    static func composeLegacyPrompt(
        basePrompt: String,
        workspace: WorkspacePrompt,
        attachments: [MediaAttachment],
        derivedTexts: [String] = []
    ) -> String {
        var sections: [String] = []
        if let bootstrap = workspace.bootstrap {
            sections.append(bootstrap)
        }
        if let skills = workspace.skills {
            sections.append(skills)
        }
        if !attachments.isEmpty {
            sections.append(Self.composeAttachmentSection(attachments))
        }
        sections.append(contentsOf: derivedTexts)
        if sections.isEmpty {
            return basePrompt
        }
        sections.append("## User Request")
        sections.append(basePrompt)
        return sections.joined(separator: "\n\n")
    }

    func composeSystemPrompt(
        workspace: WorkspacePrompt,
        request: AgentRunRequest,
        session: SessionRecord?,
        addition: String?,
        directory: String?,
        promptContext: AgentPromptContext
    ) async -> String? {
        var sections: [String] = []
        if let base = self.deps.configuration.baseSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            sections.append(base)
        }
        // The tool directory is cache-stable, so it precedes every dynamic section.
        if let directory {
            sections.append(directory)
        }
        if let bootstrap = workspace.bootstrap {
            sections.append(bootstrap)
        }
        if let skills = workspace.skills {
            sections.append(skills)
        }
        if let extra = request.extraSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            sections.append(extra)
        }
        if let addition = addition?.trimmingCharacters(in: .whitespacesAndNewlines), !addition.isEmpty {
            sections.append(addition)
        }
        if let goal = session?.goal, goal.status.isOpen {
            sections.append(goal.promptLine)
        }
        sections.append(contentsOf: await self.deps.promptContributors(promptContext).filter { !$0.isEmpty })
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    static func composeAttachmentSection(_ attachments: [MediaAttachment]) -> String {
        var lines: [String] = ["## Attachments"]
        lines.reserveCapacity(attachments.count + 1)
        for attachment in attachments {
            let trimmedName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedName.isEmpty ? "attachment-\(attachment.id.uuidString.prefix(8))" : trimmedName
            let kind = attachment.metadata["kind"] ?? "unknown"
            lines.append("- \(displayName) (\(attachment.mimeType), kind=\(kind), bytes=\(attachment.byteCount))")
        }
        return lines.joined(separator: "\n")
    }

    static func normalizeAttachments(_ attachments: [MediaAttachment], using mediaPipeline: MediaPipeline) async throws -> [MediaAttachment] {
        guard !attachments.isEmpty else { return [] }
        var normalized: [MediaAttachment] = []
        normalized.reserveCapacity(attachments.count)
        for attachment in attachments {
            normalized.append(try await mediaPipeline.prepare(attachment).attachment)
        }
        return normalized
    }

    /// Converts media the resolved model cannot read (OCR text, video frames plus a summary, audio
    /// transcripts) and reports notes and issues as `media.understanding.*` diagnostics.
    func applyMediaUnderstanding(
        _ attachments: [MediaAttachment],
        model: AgentRunModelContext,
        request: AgentRunRequest
    ) async -> [MediaAttachment] {
        guard self.deps.configuration.mediaUnderstanding, !attachments.isEmpty else { return attachments }
        let inputPolicy = MediaUnderstandingInputPolicy.resolve(
            providerConfig: model.providerConfig,
            modelID: model.modelID,
            hints: self.deps.configuration.mediaUnderstandingHints
        )
        let outcome = await self.deps.mediaPipeline.applyMediaUnderstanding(
            attachments,
            policy: inputPolicy,
            services: self.deps.mediaServices
        )
        for note in outcome.notes {
            await self.emitDiagnostic("media.understanding.converted", request: request, metadata: ["note": note, "providerID": model.providerID ?? ""])
        }
        for issue in outcome.issues {
            await self.emitDiagnostic("media.understanding.issue", request: request, metadata: ["issue": issue, "providerID": model.providerID ?? ""])
        }
        return outcome.attachments
    }

    /// Text of a derived media-understanding attachment (OCR, transcript, video summary).
    static func derivedText(from attachment: MediaAttachment) -> String? {
        guard attachment.metadata[MediaUnderstandingMetadataKey.kind] != nil,
              attachment.mimeType.lowercased().hasPrefix("text/")
        else {
            return nil
        }
        let text = String(decoding: attachment.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func imageCount(_ messages: [ModelMessage], attachments: [MediaAttachment]) -> Int {
        let fromMessages = messages.reduce(0) { total, message in
            guard case .user(let content) = message else { return total }
            return total + content.filter { part in
                if case .image = part { return true }
                return false
            }.count
        }
        return fromMessages + attachments.filter { $0.mimeType.lowercased().hasPrefix("image/") }.count
    }

    func makeModelRequest(
        from request: AgentRunRequest,
        model: AgentRunModelContext,
        runStartedAt: Int64,
        legacyPrompt: String,
        systemPrompt: String?,
        messages: [ModelMessage],
        tools: [ModelToolDefinition],
        streamTokens: Bool
    ) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: request.sessionKey,
            prompt: legacyPrompt,
            systemPrompt: systemPrompt,
            providerID: request.modelProviderID,
            modelID: request.modelID,
            metadata: Self.modelControlMetadata(from: request, thinkingLevel: model.thinkingLevel),
            policy: ModelGenerationPolicy(
                streamTokens: streamTokens,
                requestTimeoutMs: request.modelTimeoutMs,
                localRuntimeHints: self.deps.configuration.mediaUnderstandingHints,
                // Providers resolve the native effort from `thinkingLevel` (ReasoningEffortResolver).
                thinkingLevel: model.thinkingLevel,
                reasoningLevel: request.reasoningLevel,
                verboseLevel: request.verboseLevel,
                responseUsage: request.responseUsage,
                elevatedLevel: request.elevatedLevel,
                fastModeSetting: model.fastMode,
                runStartedAt: Date(timeIntervalSince1970: TimeInterval(runStartedAt) / 1_000),
                promptCache: self.deps.configuration.promptCache
            ),
            messages: messages,
            tools: tools
        )
    }

    static func modelControlMetadata(from request: AgentRunRequest, thinkingLevel: ThinkLevel?) -> [String: String] {
        var metadata: [String: String] = [:]
        if let thinkingLevel {
            metadata["thinkingLevel"] = thinkingLevel.rawValue
        }
        if let reasoningLevel = request.reasoningLevel {
            metadata["reasoningLevel"] = reasoningLevel.rawValue
        }
        if let verboseLevel = request.verboseLevel {
            metadata["verboseLevel"] = verboseLevel.rawValue
        }
        if let responseUsage = request.responseUsage {
            metadata["responseUsage"] = responseUsage.rawValue
        }
        if let elevatedLevel = request.elevatedLevel {
            metadata["elevatedLevel"] = elevatedLevel.rawValue
        }
        return metadata
    }

    func emitDiagnostic(_ name: String, request: AgentRunRequest, metadata: [String: String]) async {
        await self.emitDiagnostic(name, runID: request.runID, sessionKey: request.sessionKey, metadata: metadata)
    }

    func emitDiagnostic(_ name: String, runID: String, sessionKey: String, metadata: [String: String]) async {
        guard let sink = self.deps.diagnostics else { return }
        await sink(RuntimeDiagnosticEvent(subsystem: "runtime", name: name, runID: runID, sessionKey: sessionKey, metadata: metadata))
    }
}
