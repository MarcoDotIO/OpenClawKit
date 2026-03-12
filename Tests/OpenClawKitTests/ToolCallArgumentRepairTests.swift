import Foundation
import Testing
@testable import OpenClawKit

@Suite("Tool-call argument repair")
struct ToolCallArgumentRepairTests {
    @Test
    func repairsAnthropicCompatibleBareKeysSingleQuotesAndTrailingComma() throws {
        var repairer = ToolCallArgumentRepairer()
        let call = try AgentToolCall.repaired(
            name: "weather.lookup",
            rawArguments: "{city: 'Berlin', units: 'metric',}",
            provider: .anthropicCompatible,
            using: &repairer
        )

        #expect(repairer.lastRepairApplied == true)
        #expect(call.arguments["city"] == AnyCodable("Berlin"))
        #expect(call.arguments["units"] == AnyCodable("metric"))
    }

    @Test
    func repairsKimiCompatibleArgumentAssignmentAndBalancedBraces() throws {
        var repairer = ToolCallArgumentRepairer()
        let call = try AgentToolCall.repaired(
            name: "calendar.lookup",
            rawArguments: #"arguments={start: "2026-03-12", end: "2026-03-13""#,
            provider: .kimiCompatible,
            using: &repairer
        )

        #expect(repairer.lastRepairApplied == true)
        #expect(call.arguments["start"] == AnyCodable("2026-03-12"))
        #expect(call.arguments["end"] == AnyCodable("2026-03-13"))
    }

    @Test
    func clearsRepairStateOnceProviderResumesValidJSON() throws {
        var repairer = ToolCallArgumentRepairer(lastRepairApplied: true)
        let call = try AgentToolCall.repaired(
            name: "contacts.lookup",
            rawArguments: #"{"name":"Marco"}"#,
            provider: .anthropicCompatible,
            using: &repairer
        )

        #expect(repairer.lastRepairApplied == false)
        #expect(call.arguments["name"] == AnyCodable("Marco"))
    }

    @Test
    func repairsNestedJSONStringPayloads() throws {
        var repairer = ToolCallArgumentRepairer()
        let call = try AgentToolCall.repaired(
            name: "weather.lookup",
            rawArguments: #""{\"city\":\"Berlin\"}""#,
            provider: .anthropicCompatible,
            using: &repairer
        )

        #expect(repairer.lastRepairApplied == true)
        #expect(call.arguments["city"] == AnyCodable("Berlin"))
    }

    @Test
    func balancesMissingArrayClosuresDuringRepair() throws {
        var repairer = ToolCallArgumentRepairer()
        let call = try AgentToolCall.repaired(
            name: "items.lookup",
            rawArguments: "{items:[1,2,3",
            provider: .anthropicCompatible,
            using: &repairer
        )

        let items = try #require(call.arguments["items"])
        if case .array(let array) = items.value {
            #expect(array == [AnyCodable(1), AnyCodable(2), AnyCodable(3)])
        } else {
            Issue.record("Expected repaired items payload to be an array")
        }
    }

    @Test
    func rejectsUnrepairableOrFullyHiddenPayloads() throws {
        var repairer = ToolCallArgumentRepairer()

        do {
            _ = try AgentToolCall.repaired(
                name: "broken.lookup",
                rawArguments: "[]",
                provider: .anthropicCompatible,
                using: &repairer
            )
            Issue.record("Expected invalid configuration for non-object payload")
        } catch {
            #expect(String(describing: error).contains("Unable to decode tool-call arguments"))
        }

        do {
            _ = try AgentToolCall.repaired(
                name: "broken.lookup",
                rawArguments: "<thinking>hidden only</thinking>",
                provider: .anthropicCompatible,
                using: &repairer
            )
            Issue.record("Expected invalid configuration for hidden-only payload")
        } catch {
            #expect(String(describing: error).contains("Unable to decode tool-call arguments"))
        }
    }
}
