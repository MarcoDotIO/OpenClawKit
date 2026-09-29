import Foundation
import Testing
import OpenClawCore
import OpenClawModels
import OpenClawProtocol
import OpenClawSkills
@testable import OpenClawAgents

/// Caller- and model-controlled numbers (timeouts, limits, line counts) must clamp or fail, never trap.
@Suite("Runtime numeric hardening")
struct RuntimeNumericHardeningTests {
    private static func decoded(_ json: String) throws -> [String: AnyCodable] {
        try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
    }

    @Test
    func timeArithmeticSaturates() {
        #expect(RuntimeTime.sleepNanoseconds(milliseconds: Int64.max) == RuntimeTime.maxSleepNanoseconds)
        #expect(RuntimeTime.sleepNanoseconds(milliseconds: Int64(20_000_000_000_000)) == RuntimeTime.maxSleepNanoseconds)
        #expect(RuntimeTime.sleepNanoseconds(milliseconds: Int.max) == RuntimeTime.maxSleepNanoseconds)
        #expect(RuntimeTime.sleepNanoseconds(milliseconds: Int64(250)) == 250_000_000)
        #expect(RuntimeTime.sleepNanoseconds(milliseconds: Int64(-5)) == 0)
        #expect(RuntimeTime.maxSleepNanoseconds <= UInt64(Int64.max))
        #expect(RuntimeTime.deadline(Int64(1_000), plusMilliseconds: Int64.max) == Int64.max)
        #expect(RuntimeTime.deadline(Int64(1_000), plusMilliseconds: Int64(500)) == Int64(1_500))
        // A 30-day-old session (2.59e9 ms) exceeds Int32.max; the helper clamps instead of trapping.
        let thirtyDays = Int64(30) * 86_400_000
        #expect(RuntimeTime.elapsedMilliseconds(since: Int64(0), now: thirtyDays) == Int(clamping: thirtyDays))
        #expect(RuntimeTime.elapsedMilliseconds(since: Int64.min / 2, now: Int64.max / 2) == Int(clamping: Int64.max))
        #expect(RuntimeTime.elapsedMilliseconds(since: Int64.min, now: Int64.max) == Int.max)
        #expect(RuntimeTime.elapsedMilliseconds(since: Int64(10), now: Int64(5)) == 0)
        #expect(RuntimeTime.clampedInt(1e300, to: 1...2_000) == 2_000)
        #expect(RuntimeTime.clampedInt(-1e300, to: 1...2_000) == 1)
        #expect(RuntimeTime.clampedInt(.nan, to: 1...2_000) == nil)
        #expect(RuntimeTime.clampedInt(.infinity, to: 1...2_000) == nil)
        #expect(RuntimeTime.clampedInt(1e19, to: Int.min...Int.max) == Int.max)
        #expect(RuntimeTime.clampedInt(12.9, to: 1...2_000) == 12)
    }

    @Test
    func hugeApprovalAndQuestionTimeoutsStayPending() async throws {
        let approvals = ApprovalBroker()
        let approval = await approvals.request(presentation: .exec(commandText: "make"), timeoutMs: Int64.max)
        #expect(approval.expiresAtMs == Int64.max)
        // A huge wait bound must not trap or fire at once; a short bound returns the pending record.
        let waiter = Task { try await approvals.waitDecision(id: approval.id, timeoutMs: Int64(9_000_000_000_000_000_000)) }
        #expect(try await approvals.waitDecision(id: approval.id, timeoutMs: Int64(20)).state == .pending)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await approvals.get(id: approval.id)?.state == .pending)
        _ = await approvals.cancel(id: approval.id)
        #expect(try await waiter.value.state == .cancelled)

        let questions = QuestionBroker()
        let question = try await questions.request(
            questions: [
                AgentQuestionPrompt(
                    questionID: "q",
                    header: "Q",
                    question: "Proceed?",
                    options: [AgentQuestionOption(label: "Yes"), AgentQuestionOption(label: "No")]
                ),
            ],
            timeoutMs: Int64.max
        )
        #expect(question.expiresAtMs == Int64.max)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await questions.get(id: question.id)?.status == .pending)
        _ = try await questions.cancel(id: question.id)
    }

    @Test
    func skillReadLimitClampsHugeAndNegativeNumbers() async throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skill-read-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        try (1...30).map { "line \($0)" }.joined(separator: "\n").write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = AgentToolRegistry(tools: [SkillReadTool(access: SkillReadAccess(roots: [root]))])
        for json in [#"{"path":"SKILL.md","limit":1e30}"#, #"{"path":"SKILL.md","limit":1e300}"#, #"{"path":"SKILL.md","limit":10000000000000000000}"#] {
            let result = try await registry.invoke(AgentToolCall(name: "read", arguments: try Self.decoded(json)))
            #expect(!result.isError)
            #expect(result.output.text.contains("line 30"))
        }
        let negative = try await registry.invoke(AgentToolCall(name: "read", arguments: try Self.decoded(#"{"path":"SKILL.md","limit":-1e30}"#)))
        #expect(!negative.isError)
        #expect(negative.output.text.hasPrefix("line 1\n\n[29 more lines"))
    }

    @Test
    func skillReadLoadsOnlyABoundedPrefix() throws {
        let root = try RuntimeExtTestSupport.temporaryDirectory("skill-read-prefix")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("big.txt")
        try Data(repeating: UInt8(ascii: "a"), count: 10_000).write(to: url)
        let (prefix, size) = try SkillReadTool.readPrefix(of: url, maxBytes: 1_024)
        #expect(prefix.count == 1_024)
        #expect(size == 10_000)
    }

    @Test
    func llmTaskRejectsOrClampsHugeNumbers() async throws {
        let provider = ScriptedToolProvider(turns: [], fallback: ScriptedToolProvider.text(#"{"ok":true}"#))
        let tool = LLMTaskTool(modelRouter: ModelRouter(defaultProviderID: provider.id, providers: [provider]))
        #expect(LLMTaskTool.parametersSchema["properties"]?.dictionaryValue?["timeoutMs"]?.dictionaryValue?["maximum"] == AnyCodable(LLMTaskTool.maxTimeoutMs))
        let clamped = try await tool.execute(arguments: try Self.decoded(#"{"prompt":"x","timeoutMs":100000000000000}"#))
        #expect(clamped.dictionaryValue?["ok"]?.boolValue == true)
        for json in [#"{"prompt":"x","timeoutMs":1e300}"#, #"{"prompt":"x","maxTokens":1e19}"#, #"{"prompt":"x","maxTokens":-1e300}"#] {
            await #expect(throws: LLMTaskToolError.self) {
                _ = try await tool.execute(arguments: try Self.decoded(json))
            }
        }
    }
}
