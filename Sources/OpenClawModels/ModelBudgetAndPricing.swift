import Foundation
import OpenClawCore
import OpenClawProtocol

/// Context-window budgeting helpers (upstream `packages/llm-core/src/model-data.ts`,
/// `model-catalog-types.ts`).
public enum ModelContextBudget {
    /// Effective context budget for a model.
    ///
    /// Order: the selected context-window option, the catalog default option, the runtime cap
    /// `contextTokens`, then the native `contextWindow`. For example OpenAI GPT-6 rows declare
    /// `contextWindow` 1,050,000 and `contextTokens` 272,000, so the budget is 272,000.
    /// - Parameters:
    ///   - model: Model definition.
    ///   - contextWindowOptions: Catalog context-window options keyed by option id (for example
    ///     `["200k": 200_000, "1m": 1_000_000]`).
    ///   - selectedContextWindowID: Option id chosen by the user, if any.
    ///   - contextWindowDefault: Catalog default option id, if any.
    /// - Returns: Token budget, or `nil` when nothing is known.
    public static func effectiveContextBudget(
        model: ModelDefinitionConfig,
        contextWindowOptions: [String: Int] = [:],
        selectedContextWindowID: String? = nil,
        contextWindowDefault: String? = nil
    ) -> Int? {
        if let selectedContextWindowID, let window = contextWindowOptions[selectedContextWindowID], window > 0 {
            return window
        }
        if let contextWindowDefault, let window = contextWindowOptions[contextWindowDefault], window > 0 {
            return window
        }
        if let contextTokens = model.contextTokens, contextTokens > 0 {
            return contextTokens
        }
        return model.contextWindow > 0 ? model.contextWindow : nil
    }
}

/// Usage cost computation from model pricing (prices are USD per million tokens).
public enum ModelCostCalculator {
    /// Prices applied to one request.
    public struct Prices: Sendable, Equatable {
        /// Input price per million tokens.
        public var input: Double
        /// Output price per million tokens.
        public var output: Double
        /// Cache-read price per million tokens.
        public var cacheRead: Double
        /// Cache-write price per million tokens.
        public var cacheWrite: Double
    }

    /// Prices for a prompt size: the tier whose half-open `range` contains the prompt tokens, else
    /// the flat prices.
    /// - Parameters:
    ///   - cost: Model cost config.
    ///   - promptTokens: Prompt tokens (input plus cache reads and writes).
    public static func prices(for cost: ModelCostConfig, promptTokens: Int) -> Prices {
        if let tier = cost.tieredPricing?.first(where: { $0.contains(promptTokens: promptTokens) }) {
            return Prices(input: tier.input, output: tier.output, cacheRead: tier.cacheRead, cacheWrite: tier.cacheWrite)
        }
        return Prices(input: cost.input, output: cost.output, cacheRead: cost.cacheRead, cacheWrite: cost.cacheWrite)
    }

    /// Cost of one response in USD.
    /// - Parameters:
    ///   - usage: Token usage.
    ///   - model: Model definition providing prices.
    ///   - multiplier: Price multiplier (for example 2 for Anthropic native fast mode).
    /// - Returns: Cost in USD.
    public static func cost(usage: ModelUsage, model: ModelDefinitionConfig, multiplier: Double = 1) -> Double {
        let promptTokens = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        let prices = self.prices(for: model.cost, promptTokens: promptTokens)
        let total = Double(usage.inputTokens) * prices.input
            + Double(usage.outputTokens) * prices.output
            + Double(usage.cacheReadTokens) * prices.cacheRead
            + Double(usage.cacheWriteTokens) * prices.cacheWrite
        return total / 1_000_000 * max(0, multiplier)
    }
}

extension ModelGenerationRequest {
    /// Copy with replaced transcript content (used by media-input preparation).
    func replacingContent(messages: [ModelMessage], attachments: [MediaAttachment]) -> ModelGenerationRequest {
        ModelGenerationRequest(
            sessionKey: self.sessionKey,
            prompt: self.prompt,
            systemPrompt: self.systemPrompt,
            providerID: self.providerID,
            modelID: self.modelID,
            preferredAuthProfileID: self.preferredAuthProfileID,
            metadata: self.metadata,
            headers: self.headers,
            policy: self.policy,
            attachments: attachments,
            messages: messages,
            tools: self.tools,
            toolChoice: self.toolChoice,
            responseFormat: self.responseFormat
        )
    }
}

/// Applies a model's `mediaInput.image` limits to every image in a request before encoding.
enum MediaInputPreparation {
    static func apply(_ request: ModelGenerationRequest, limits: ModelImageInputLimits?) -> ModelGenerationRequest {
        guard let limits, limits.maxSidePx != nil || limits.preferredSidePx != nil || limits.maxBytes != nil || limits.maxPixels != nil else {
            return request
        }
        let hasImages = request.attachments.contains(where: Self.isImage)
            || request.messages.contains { message in
                switch message {
                case .user(let content), .system(let content):
                    return content.contains { if case .image = $0 { return true } else { return false } }
                case .toolResult(let result):
                    return result.content.contains { if case .image = $0 { return true } else { return false } }
                case .assistant:
                    return false
                }
            }
        guard hasImages else { return request }
        let attachments = request.attachments.map { Self.isImage($0) ? MultimodalAttachmentUtilities.prepareImage($0, limits: limits) : $0 }
        let messages = request.messages.map { message -> ModelMessage in
            switch message {
            case .user(let content):
                return .user(content: content.map { Self.prepare($0, limits: limits) })
            case .system(let content):
                return .system(content: content.map { Self.prepare($0, limits: limits) })
            case .toolResult(var result):
                result.content = result.content.map { Self.prepare($0, limits: limits) }
                return .toolResult(result)
            case .assistant:
                return message
            }
        }
        return request.replacingContent(messages: messages, attachments: attachments)
    }

    private static func prepare(_ part: ModelContentPart, limits: ModelImageInputLimits) -> ModelContentPart {
        guard case .image(let attachment) = part else { return part }
        return .image(MultimodalAttachmentUtilities.prepareImage(attachment, limits: limits))
    }

    private static func isImage(_ attachment: MediaAttachment) -> Bool {
        MultimodalAttachmentUtilities.normalizedMimeType(for: attachment).hasPrefix("image/")
    }
}
