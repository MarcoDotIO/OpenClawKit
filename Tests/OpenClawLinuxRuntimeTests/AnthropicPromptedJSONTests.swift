import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawModels

// Live finding (claude-haiku-4-5): with a JSON-schema response format the model returned the object
// inside a ```json fence, so `response.text` did not decode.
@Suite("Anthropic prompted JSON output")
struct AnthropicPromptedJSONTests {
    private let schema: ModelResponseFormat = .jsonSchema(
        name: "city",
        schema: ["type": AnyCodable("object")],
        strict: true
    )

    @Test
    func fencedJSONIsUnwrappedWhenAJSONFormatWasRequested() throws {
        let fenced = "```json\n{\"city\": \"Paris\", \"country\": \"France\"}\n```"
        let response = ModelGenerationResponse(text: fenced, providerID: "anthropic", modelID: "claude-haiku-4-5")
        let normalized = AnthropicMessagesWire.normalizingPromptedJSON(response, format: self.schema)
        #expect(normalized.text == "{\"city\": \"Paris\", \"country\": \"France\"}")
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(normalized.text.utf8))
        #expect(decoded["city"] == "Paris")
        #expect(normalized.modelID == "claude-haiku-4-5")
        #expect(normalized.stopReason == response.stopReason)
        #expect(AnthropicMessagesWire.normalizingPromptedJSON(response, format: .jsonObject).text == normalized.text)
    }

    @Test
    func plainTextAndToolCallResponsesAreUntouched() {
        let fenced = "```json\n{\"a\": 1}\n```"
        let text = ModelGenerationResponse(text: fenced, providerID: "anthropic")
        #expect(AnthropicMessagesWire.normalizingPromptedJSON(text, format: .text).text == fenced)
        let toolCall = ModelGenerationResponse(
            text: fenced,
            providerID: "anthropic",
            toolCalls: [ModelToolCall(id: "call-1", name: "lookup", arguments: [:])]
        )
        #expect(AnthropicMessagesWire.normalizingPromptedJSON(toolCall, format: self.schema).text == fenced)
        let bare = ModelGenerationResponse(text: "{\"a\": 1}", providerID: "anthropic")
        #expect(AnthropicMessagesWire.normalizingPromptedJSON(bare, format: self.schema).text == "{\"a\": 1}")
    }
}
