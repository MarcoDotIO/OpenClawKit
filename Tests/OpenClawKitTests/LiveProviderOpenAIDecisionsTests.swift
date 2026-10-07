import Foundation
import OpenClawModels
import Testing

/// Small live check of all Decisions question types. Opt-in only; credentials come from `.env` via the process environment.
@Suite("Live OpenAI Decisions", .serialized,
       .enabled(if: LiveProviderEnvironment.isEnabled(.openAI), "needs OPENCLAW_LIVE_PROVIDER_TESTS=1 and OPENAI_API_KEY"))
struct LiveProviderOpenAIDecisionsTests {
    @Test
    func predicateChoiceAndScoreReportTypedAnswersAndUsage() async throws {
        let client = try OpenAIDecisionsClient(apiKey: #require(LiveProviderEnvironment.apiKey(.openAI)))
        let response = try await liveCall {
            try await client.create(.init(input: .text("The customer says: I was charged twice for my order."), questions: [
                .predicate(name: "billing_issue", instructions: "Does the customer report a billing issue?"),
                .choice(name: "department", instructions: "Choose the responsible department", choices: [
                    .init(value: .string("billing"), description: "Charges or payments"),
                    .init(value: .string("shipping"), description: "Delivery or tracking")
                ]),
                .score(name: "urgency", instructions: "Rate the issue's urgency", levels: [
                    .init(label: "Low", description: "Informational request"),
                    .init(label: "High", description: "Money or access is affected")
                ])
            ]))
        }
        LiveUsageLedger.record("openai-decisions.allTypes", model: response.model, usage: response.usage.modelUsage)
        #expect(response.answers.count == 3)
        #expect(response.model.hasPrefix("gpt-6-luna"))
        #expect(response.usage.inputTokens > 0)
        #expect(response.usage.outputTokens == 0)
        guard case .predicate(_, let probability) = response.answers[0],
              case .choice(_, let choice, let confidence, let probabilities) = response.answers[1],
              case .score(_, let score, _, let levels) = response.answers[2] else {
            Issue.record("Expected predicate, choice, and score answers")
            return
        }
        #expect((0...1).contains(probability))
        #expect([OpenAIDecisionChoiceValue.string("billing"), .string("shipping")].contains(choice))
        #expect((0...1).contains(confidence))
        #expect(probabilities.count == 2)
        #expect((0...1).contains(score))
        #expect(levels.map(\.value) == [0, 1])
    }

    @Test
    func inlineImageAndBooleanChoicesAreAccepted() async throws {
        let client = try OpenAIDecisionsClient(apiKey: #require(LiveProviderEnvironment.apiKey(.openAI)))
        let response = try await liveCall {
            try await client.create(.init(input: .messages([
                .init(content: .parts([
                    .text("Inspect the color of this image."),
                    .image(data: LiveProviderFixtures.redSquarePNG, mimeType: "image/png", detail: .low)
                ]))
            ]), questions: [
                .choice(name: "red", instructions: "Is the image predominantly red?", choices: [
                    .init(value: .bool(true), description: "The image is predominantly red"),
                    .init(value: .bool(false), description: "The image is another color")
                ])
            ]))
        }
        LiveUsageLedger.record("openai-decisions.imageBoolean", model: response.model, usage: response.usage.modelUsage)
        guard case .choice(_, let choice, _, let probabilities) = response.answers[0] else {
            Issue.record("Expected a Boolean choice answer")
            return
        }
        #expect([OpenAIDecisionChoiceValue.bool(true), .bool(false)].contains(choice))
        #expect(Set(probabilities.map(\.value)) == [.bool(true), .bool(false)])
        #expect(response.usage.inputTokens > 0)
    }
}
