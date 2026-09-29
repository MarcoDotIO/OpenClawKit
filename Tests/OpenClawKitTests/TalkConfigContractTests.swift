import Foundation
import OpenClawKit
import Testing

/// Upstream contract fixture `test/fixtures/talk-config-contract.json` (OpenClaw v2026.9.6),
/// embedded so the test target needs no resource bundle.
private let talkConfigContractFixtureJSON = #"""
{
  "selectionCases": [
    {
      "id": "canonical_resolved_wins",
      "defaultProvider": "elevenlabs",
      "payloadValid": true,
      "expectedSelection": {
        "provider": "elevenlabs",
        "normalizedPayload": true,
        "voiceId": "voice-normalized",
        "apiKey": "xxxxx"
      },
      "talk": {
        "resolved": {
          "provider": "elevenlabs",
          "config": { "voiceId": "voice-resolved", "apiKey": "xxxxx" }
        },
        "provider": "elevenlabs",
        "providers": { "elevenlabs": { "voiceId": "voice-normalized", "apiKey": "xxxxx" } },
        "voiceId": "voice-legacy",
        "apiKey": "xxxxx"
      }
    },
    {
      "id": "normalized_missing_resolved",
      "defaultProvider": "elevenlabs",
      "payloadValid": true,
      "expectedSelection": {
        "provider": "elevenlabs",
        "normalizedPayload": true,
        "voiceId": "voice-normalized"
      },
      "talk": {
        "provider": "elevenlabs",
        "providers": { "elevenlabs": { "voiceId": "voice-normalized" } },
        "voiceId": "voice-legacy"
      }
    },
    {
      "id": "provider_mismatch_missing_resolved",
      "defaultProvider": "elevenlabs",
      "payloadValid": true,
      "expectedSelection": null,
      "talk": {
        "provider": "acme",
        "providers": { "elevenlabs": { "voiceId": "voice-normalized" } }
      }
    },
    {
      "id": "ambiguous_providers_missing_resolved",
      "defaultProvider": "elevenlabs",
      "payloadValid": true,
      "expectedSelection": null,
      "talk": {
        "providers": {
          "acme": { "voiceId": "voice-acme" },
          "elevenlabs": { "voiceId": "voice-normalized" }
        }
      }
    }
  ],
  "timeoutCases": [
    { "id": "integer_timeout_kept", "fallback": 700, "expectedTimeoutMs": 1500, "talk": { "silenceTimeoutMs": 1500 } },
    { "id": "integer_like_double_timeout_kept", "fallback": 700, "expectedTimeoutMs": 1500, "talk": { "silenceTimeoutMs": 1500.0 } },
    { "id": "zero_timeout_falls_back", "fallback": 700, "expectedTimeoutMs": 700, "talk": { "silenceTimeoutMs": 0 } },
    { "id": "boolean_timeout_falls_back", "fallback": 700, "expectedTimeoutMs": 700, "talk": { "silenceTimeoutMs": true } },
    { "id": "string_timeout_falls_back", "fallback": 700, "expectedTimeoutMs": 700, "talk": { "silenceTimeoutMs": "1500" } },
    { "id": "fractional_timeout_falls_back", "fallback": 700, "expectedTimeoutMs": 700, "talk": { "silenceTimeoutMs": 1500.5 } }
  ]
}
"""#

private struct TalkConfigContractFixture: Decodable {
    let selectionCases: [SelectionCase]
    let timeoutCases: [TimeoutCase]

    struct SelectionCase: Decodable {
        let id: String
        let defaultProvider: String
        let payloadValid: Bool
        let expectedSelection: ExpectedSelection?
        let talk: [String: AnyCodable]

        /// The gateway answers `talk.config` with the canonical `resolved` block; rebuild it the
        /// way the gateway does from the fixture's expected selection.
        var gatewayResponseTalk: [String: AnyCodable] {
            guard let expectedSelection else { return self.talk }
            var config: [String: AnyCodable] = [:]
            if let voiceId = expectedSelection.voiceId {
                config["voiceId"] = AnyCodable(voiceId)
            }
            if let apiKey = expectedSelection.apiKey {
                config["apiKey"] = AnyCodable(apiKey)
            }
            var response = self.talk
            response["provider"] = AnyCodable(expectedSelection.provider)
            response["providers"] = AnyCodable([expectedSelection.provider: config])
            response["resolved"] = AnyCodable([
                "provider": AnyCodable(expectedSelection.provider),
                "config": AnyCodable(config),
            ] as [String: AnyCodable])
            return response
        }
    }

    struct ExpectedSelection: Decodable {
        let provider: String
        let normalizedPayload: Bool
        let voiceId: String?
        let apiKey: String?
    }

    struct TimeoutCase: Decodable {
        let id: String
        let fallback: Int
        let expectedTimeoutMs: Int
        let talk: [String: AnyCodable]
    }

    static func load() throws -> TalkConfigContractFixture {
        try JSONDecoder().decode(TalkConfigContractFixture.self, from: Data(talkConfigContractFixtureJSON.utf8))
    }
}

@Suite("Talk config contract fixture")
struct TalkConfigContractTests {
    @Test("selection fixtures")
    func selectionFixtures() throws {
        let fixture = try TalkConfigContractFixture.load()
        #expect(fixture.selectionCases.count == 4)
        for testCase in fixture.selectionCases {
            let selection = TalkConfigParsing.selectProviderConfig(
                testCase.gatewayResponseTalk,
                defaultProvider: testCase.defaultProvider)
            let snapshot = TalkConfigSnapshot(
                testCase.gatewayResponseTalk,
                defaultProvider: testCase.defaultProvider,
                defaultSilenceTimeoutMs: 700)
            if let expected = testCase.expectedSelection {
                #expect(selection != nil, "\(testCase.id)")
                #expect(selection?.provider == expected.provider, "\(testCase.id)")
                #expect(selection?.normalizedPayload == expected.normalizedPayload, "\(testCase.id)")
                #expect(selection?.config["voiceId"]?.stringValue == expected.voiceId, "\(testCase.id)")
                #expect(selection?.config["apiKey"]?.stringValue == expected.apiKey, "\(testCase.id)")
                #expect(snapshot.activeProvider == expected.provider, "\(testCase.id)")
                #expect(!snapshot.missingResolvedPayload, "\(testCase.id)")
            } else {
                #expect(selection == nil, "\(testCase.id)")
                #expect(snapshot.missingResolvedPayload, "\(testCase.id)")
            }
        }
    }

    @Test("timeout fixtures")
    func timeoutFixtures() throws {
        let fixture = try TalkConfigContractFixture.load()
        #expect(fixture.timeoutCases.count == 6)
        for testCase in fixture.timeoutCases {
            #expect(
                TalkConfigParsing.resolvedSilenceTimeoutMs(testCase.talk, fallback: testCase.fallback)
                    == testCase.expectedTimeoutMs,
                "\(testCase.id)")
        }
    }
}
