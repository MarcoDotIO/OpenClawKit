import Foundation

/// Probability assigned to a typed choice value.
public struct OpenAIDecisionChoiceProbability: Sendable, Equatable, Decodable {
    /// String or Boolean category value.
    public let value: OpenAIDecisionChoiceValue
    /// Probability of this category.
    public let probability: Double
}

/// Probability assigned to an ordered rubric level.
public struct OpenAIDecisionScoreProbability: Sendable, Equatable, Decodable {
    /// Zero-based level index.
    public let value: Int
    /// Label of this level.
    public let label: String
    /// Probability of this level.
    public let probability: Double
}

/// An answer or per-question refusal from the Decisions endpoint.
public enum OpenAIDecisionAnswer: Sendable, Equatable, Decodable {
    /// Probability that the question's condition is true.
    case predicate(name: String?, probability: Double)
    /// Selected category, confidence, and the category distribution.
    case choice(name: String?, choice: OpenAIDecisionChoiceValue, confidence: Double, probabilities: [OpenAIDecisionChoiceProbability])
    /// Probability-weighted level index, confidence, and the level distribution.
    case score(name: String?, score: Double, confidence: Double, probabilities: [OpenAIDecisionScoreProbability])
    /// The model declined this question; other answers remain available.
    case refusal(name: String?)

    /// Question name, or `nil` for an unnamed question.
    public var name: String? {
        switch self {
        case .predicate(let name, _), .choice(let name, _, _, _), .score(let name, _, _, _), .refusal(let name): return name
        }
    }

    var type: String {
        switch self {
        case .predicate: return "predicate"
        case .choice: return "choice"
        case .score: return "score"
        case .refusal: return "refusal"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, name, probability, choice, confidence, probabilities, score }

    /// Decodes the tagged answer; unknown or incomplete answer types fail decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        switch try container.decode(String.self, forKey: .type) {
        case "predicate":
            self = .predicate(name: name, probability: try container.decode(Double.self, forKey: .probability))
        case "choice":
            self = .choice(
                name: name,
                choice: try container.decode(OpenAIDecisionChoiceValue.self, forKey: .choice),
                confidence: try container.decode(Double.self, forKey: .confidence),
                probabilities: try container.decode([OpenAIDecisionChoiceProbability].self, forKey: .probabilities)
            )
        case "score":
            self = .score(
                name: name,
                score: try container.decode(Double.self, forKey: .score),
                confidence: try container.decode(Double.self, forKey: .confidence),
                probabilities: try container.decode([OpenAIDecisionScoreProbability].self, forKey: .probabilities)
            )
        case "refusal": self = .refusal(name: name)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Decisions answer type")
        }
    }
}

/// Token counters returned by Decisions, preserving OpenAI's inclusive input-token count.
public struct OpenAIDecisionUsage: Sendable, Equatable, Decodable {
    /// Total input tokens, including cached tokens.
    public let inputTokens: Int
    /// Output tokens (currently zero for Decisions).
    public let outputTokens: Int
    /// Total tokens reported by OpenAI.
    public let totalTokens: Int
    /// Input tokens served from cache.
    public var cachedTokens: Int { self.inputDetails.cachedTokens }
    /// Input tokens written to cache.
    public var cacheWriteTokens: Int { self.inputDetails.cacheWriteTokens }
    /// Reasoning output tokens.
    public var reasoningTokens: Int { self.outputDetails.reasoningTokens }
    /// Counters normalized to OpenClaw's usage convention (uncached input plus cache counters).
    public var modelUsage: ModelUsage {
        ModelUsage(
            inputTokens: max(0, self.inputTokens - self.cachedTokens - self.cacheWriteTokens),
            outputTokens: self.outputTokens,
            cacheReadTokens: self.cachedTokens,
            cacheWriteTokens: self.cacheWriteTokens,
            reasoningTokens: self.reasoningTokens,
            totalTokens: self.totalTokens
        )
    }

    private let inputDetails: InputDetails
    private let outputDetails: OutputDetails

    private struct InputDetails: Sendable, Equatable, Decodable {
        let cachedTokens: Int
        let cacheWriteTokens: Int
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }
    }
    private struct OutputDetails: Sendable, Equatable, Decodable {
        let reasoningTokens: Int
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
    }
    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputDetails = "input_tokens_details"
        case outputDetails = "output_tokens_details"
    }
}

/// Ordered answers and token usage from an official Decisions request.
public struct OpenAIDecisionResponse: Sendable, Equatable, Decodable {
    /// Answers in question order, including any per-question refusals.
    public let answers: [OpenAIDecisionAnswer]
    /// Model used by the server.
    public let model: String
    /// Usage counters from the server.
    public let usage: OpenAIDecisionUsage

    /// Looks up the first answer with the supplied question name.
    /// - Parameter name: Question name.
    /// - Returns: Matching answer, including a refusal, or `nil`.
    public func answer(named name: String) -> OpenAIDecisionAnswer? {
        self.answers.first { $0.name == name }
    }
}
