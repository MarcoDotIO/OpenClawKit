import Foundation
import OpenClawCore

/// A Decisions choice value. Boolean and string values remain distinct on the wire.
public enum OpenAIDecisionChoiceValue: Sendable, Equatable, Hashable, Codable {
    /// A string category.
    case string(String)
    /// A Boolean category.
    case bool(Bool)

    /// Decodes a string or Boolean without coercion.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    /// Encodes the original JSON value type.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// One allowed category in a choice question.
public struct OpenAIDecisionChoice: Sendable, Equatable, Encodable {
    /// Value returned when this category is selected.
    public var value: OpenAIDecisionChoiceValue
    /// Optional criteria for this category.
    public var description: String?

    /// Creates a category with optional criteria.
    public init(value: OpenAIDecisionChoiceValue, description: String? = nil) {
        self.value = value
        self.description = description
    }
}

/// One ordered rubric level; its position is its zero-based numeric value.
public struct OpenAIDecisionScoreLevel: Sendable, Equatable, Encodable {
    /// Human-readable level label.
    public var label: String
    /// Optional criteria for this level.
    public var description: String?

    /// Creates a rubric level with optional criteria.
    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// A typed question evaluated against shared evidence by the official Decisions API.
public enum OpenAIDecisionQuestion: Sendable, Equatable, Encodable {
    /// Estimates the probability that a condition is true.
    case predicate(name: String? = nil, instructions: String)
    /// Selects one of 2...255 distinct string or Boolean values.
    case choice(name: String? = nil, instructions: String, choices: [OpenAIDecisionChoice])
    /// Returns a probability-weighted score over ordered rubric levels.
    case score(name: String? = nil, instructions: String, levels: [OpenAIDecisionScoreLevel])

    /// Optional name echoed by the answer.
    public var name: String? {
        switch self {
        case .predicate(let name, _), .choice(let name, _, _), .score(let name, _, _): return name
        }
    }

    var type: String {
        switch self {
        case .predicate: return "predicate"
        case .choice: return "choice"
        case .score: return "score"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, name, instructions, choices, levels }

    /// Encodes a question using the endpoint's discriminated JSON schema.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encodeIfPresent(self.name, forKey: .name)
        switch self {
        case .predicate(_, let instructions):
            try container.encode(instructions, forKey: .instructions)
        case .choice(_, let instructions, let choices):
            try container.encode(instructions, forKey: .instructions)
            try container.encode(choices, forKey: .choices)
        case .score(_, let instructions, let levels):
            try container.encode(instructions, forKey: .instructions)
            try container.encode(levels, forKey: .levels)
        }
    }
}

/// Image resolution requested from the Decisions model.
public enum OpenAIDecisionImageDetail: String, Sendable, Codable {
    /// Let the model choose the image resolution.
    case auto
    /// Use low resolution.
    case low
    /// Use high resolution.
    case high
    /// Preserve original resolution.
    case original
}

/// Text or an inline image in a Decisions user message.
public enum OpenAIDecisionInputPart: Sendable, Equatable, Encodable {
    /// Text evidence.
    case text(String)
    /// An inline base64 image data URL; hosted URLs and file ids are unsupported.
    case image(dataURL: String, detail: OpenAIDecisionImageDetail? = nil)

    /// Creates an image part from bytes, without uploading a file.
    /// - Parameters:
    ///   - data: Image bytes.
    ///   - mimeType: Image MIME type, such as `image/png`.
    ///   - detail: Optional resolution setting.
    public static func image(data: Data, mimeType: String, detail: OpenAIDecisionImageDetail? = nil) -> Self {
        .image(dataURL: "data:\(mimeType);base64,\(data.base64EncodedString())", detail: detail)
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, detail
        case imageURL = "image_url"
    }

    /// Encodes an `input_text` or `input_image` part.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let dataURL, let detail):
            try container.encode("input_image", forKey: .type)
            try container.encode(dataURL, forKey: .imageURL)
            try container.encodeIfPresent(detail, forKey: .detail)
        }
    }
}

/// Content of a Decisions user message, as text or ordered text/image parts.
public enum OpenAIDecisionMessageContent: Sendable, Equatable, Encodable {
    /// Plain text content.
    case text(String)
    /// Ordered text and inline image content.
    case parts([OpenAIDecisionInputPart])

    /// Encodes the content as a string or array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

/// A user message. The Decisions endpoint accepts only the user role.
public struct OpenAIDecisionInputMessage: Sendable, Equatable, Encodable {
    /// Shared evidence in this message.
    public var content: OpenAIDecisionMessageContent

    /// Creates a user message from text or parts.
    public init(content: OpenAIDecisionMessageContent) {
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case role, content }

    /// Encodes content with the fixed `user` role.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("user", forKey: .role)
        try container.encode(self.content, forKey: .content)
    }
}

/// Shared evidence for all questions in a Decisions request.
public enum OpenAIDecisionInput: Sendable, Equatable, Encodable {
    /// Plain text evidence.
    case text(String)
    /// User messages with text and up to 128 inline images across the request.
    case messages([OpenAIDecisionInputMessage])

    /// Encodes evidence as a string or user-message array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .messages(let messages): try container.encode(messages)
        }
    }
}

/// Request for `POST /v1/decisions`; no generation, streaming, or tool fields are sent.
public struct OpenAIDecisionRequest: Sendable, Equatable, Encodable {
    /// Model id. The public beta currently supports `gpt-6-luna`.
    public var model: String
    /// Evidence shared by every question.
    public var input: OpenAIDecisionInput
    /// Questions evaluated in order.
    public var questions: [OpenAIDecisionQuestion]
    /// Optional opaque end-user identifier, at most 128 characters.
    public var safetyIdentifier: String?

    /// Creates a request with the documented beta model by default.
    public init(
        model: String = "gpt-6-luna",
        input: OpenAIDecisionInput,
        questions: [OpenAIDecisionQuestion],
        safetyIdentifier: String? = nil
    ) {
        self.model = model
        self.input = input
        self.questions = questions
        self.safetyIdentifier = safetyIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case model, input, questions
        case safetyIdentifier = "safety_identifier"
    }

    func validate() throws {
        guard !self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.questions.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("Decisions needs a model and at least one question")
        }
        let names = self.questions.compactMap(\.name)
        guard Set(names).count == names.count else {
            throw OpenClawCoreError.invalidConfiguration("Decisions question names must be unique")
        }
        guard (self.safetyIdentifier?.unicodeScalars.count ?? 0) <= 128 else {
            throw OpenClawCoreError.invalidConfiguration("Decisions safety identifier exceeds 128 characters")
        }
        for question in self.questions {
            switch question {
            case .predicate: break
            case .choice(_, _, let choices):
                guard (2...255).contains(choices.count), Set(choices.map(\.value)).count == choices.count else {
                    throw OpenClawCoreError.invalidConfiguration("Decisions needs 2...255 distinct choices")
                }
            case .score(_, _, let levels):
                guard !levels.isEmpty else {
                    throw OpenClawCoreError.invalidConfiguration("Decisions score questions need rubric levels")
                }
            }
        }
        if case .messages(let messages) = self.input {
            var imageCount = 0
            for message in messages {
                guard case .parts(let parts) = message.content else { continue }
                for part in parts {
                    guard case .image(let dataURL, _) = part else { continue }
                    imageCount += 1
                    let segments = dataURL.components(separatedBy: ";base64,")
                    guard segments.count == 2, segments[0].hasPrefix("data:image/"),
                          !segments[1].isEmpty, Data(base64Encoded: segments[1]) != nil else {
                        throw OpenClawCoreError.invalidConfiguration("Decisions images must be inline base64 image data URLs")
                    }
                }
            }
            guard imageCount <= 128 else {
                throw OpenClawCoreError.invalidConfiguration("Decisions accepts at most 128 images per request")
            }
        }
    }
}
