import Foundation
import Testing
@testable import OpenClawKit

private func temporaryStateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("openclaw-exec-approvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func invoke(
    _ handler: OpenClawSystemExecApprovalsHandler,
    _ command: OpenClawSystemCommand,
    params: String?) -> BridgeInvokeResponse?
{
    handler.handle(BridgeInvokeRequest(id: "req-1", command: command.rawValue, paramsJSON: params))
}

@Suite("System exec approvals node commands")
struct SystemExecApprovalsNodeCommandsTests {
    @Test
    func getOnAnEmptyStoreReportsAMissingDocument() throws {
        let directory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = OpenClawSystemExecApprovalsHandler(stateDirectoryURL: directory)
        let snapshot = try handler.snapshot(includeResolvedDefaults: true)
        #expect(snapshot.exists == false)
        #expect(snapshot.hash == OpenClawSystemExecApprovalsHandler.hash(rawJSON: nil))
        #expect(snapshot.hash.hasPrefix("missing:"))
        #expect(snapshot.file.version == 1)
        #expect(snapshot.resolvedDefaults == OpenClawExecApprovalsResolvedDefaults(document: nil))
        #expect(snapshot.resolvedDefaults?.security == .full)
        #expect(snapshot.path.hasSuffix("state/openclaw.sqlite"))
    }

    @Test
    func setRequiresTheCurrentBaseHashAndNeverReportsTheSocketToken() throws {
        let directory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = OpenClawSystemExecApprovalsHandler(stateDirectoryURL: directory)
        let document = ExecApprovalsDocument(
            version: 1,
            defaults: ExecApprovalsDefaultsDocument(security: .allowlist, ask: .onMiss),
            agents: ["main": ExecApprovalsAgentDocument(allowlist: [ExecApprovalsAllowlistEntry(pattern: "/usr/bin/git")])])

        let first = try handler.apply(OpenClawSystemExecApprovalsSetParams(file: document))
        #expect(first.exists)
        #expect(first.file.socket?.token == nil)
        #expect(first.file.socket?.path == directory.appendingPathComponent("exec-approvals.sock").path)
        let stored = try #require(try ExecApprovalsSQLiteStore.read(stateDirectoryURL: directory))
        let token = try #require(stored.document.socket?.token)
        #expect(token.count >= 32)
        #expect(first.hash == OpenClawSystemExecApprovalsHandler.hash(rawJSON: stored.rawJSON))

        #expect(throws: OpenClawNodeError.self) {
            try handler.apply(OpenClawSystemExecApprovalsSetParams(file: document))
        }
        #expect(throws: OpenClawNodeError.self) {
            try handler.apply(OpenClawSystemExecApprovalsSetParams(file: document, baseHash: "stale"))
        }

        var updated = document
        updated.defaults?.ask = .always
        let second = try handler.apply(OpenClawSystemExecApprovalsSetParams(file: updated, baseHash: first.hash))
        #expect(second.hash != first.hash)
        let restored = try #require(try ExecApprovalsSQLiteStore.read(stateDirectoryURL: directory))
        #expect(restored.document.socket?.token == token)
        #expect(restored.document.defaults?.ask == .always)
    }

    @Test
    func invokeHandlerRoutesOnlyExecApprovalsCommands() throws {
        let directory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = OpenClawSystemExecApprovalsHandler(stateDirectoryURL: directory)

        let get = try #require(invoke(handler, .execApprovalsGet, params: #"{"includeResolvedDefaults":true}"#))
        #expect(get.ok)
        let payload = try JSONDecoder().decode(
            OpenClawExecApprovalsSnapshot.self,
            from: Data(try #require(get.payloadJSON).utf8))
        #expect(payload.resolvedDefaults?.askFallback == .deny)

        let missingFile = try #require(invoke(handler, .execApprovalsSet, params: nil))
        #expect(missingFile.ok == false)
        #expect(missingFile.error?.code == .invalidRequest)

        let set = try #require(invoke(handler, .execApprovalsSet, params: #"{"file":{"version":1,"agents":{}}}"#))
        #expect(set.ok)
        let stale = try #require(invoke(handler, .execApprovalsSet, params: #"{"file":{"version":1},"baseHash":"x"}"#))
        #expect(stale.error?.message == "INVALID_REQUEST: exec approvals changed; reload and retry")

        #expect(invoke(handler, .run, params: "{}") == nil)
    }

    @Test
    func policySnapshotResolvesAgentOverWildcardOverDefaults() {
        let document = ExecApprovalsDocument(
            version: 1,
            defaults: ExecApprovalsDefaultsDocument(security: .allowlist, ask: .onMiss, askFallback: .deny, autoAllowSkills: true),
            agents: [
                "*": ExecApprovalsAgentDocument(
                    ask: .always,
                    allowlist: [ExecApprovalsAllowlistEntry(pattern: "/bin/ls")]),
                "ops": ExecApprovalsAgentDocument(
                    security: .full,
                    allowlist: [ExecApprovalsAllowlistEntry(pattern: "/usr/bin/git", source: "allow-always")]),
            ])
        let ops = OpenClawSystemRunApprovalPolicySnapshot(document: document, agentId: " ops ")
        #expect(ops.security == .full)
        #expect(ops.ask == .always)
        #expect(ops.askFallback == .deny)
        #expect(ops.autoAllowSkills)
        #expect(ops.allowlistRules == [
            .init(pattern: "/bin/ls"),
            .init(pattern: "/usr/bin/git", source: .allowAlways),
        ])
        let main = OpenClawSystemRunApprovalPolicySnapshot(document: document, agentId: nil)
        #expect(main.security == .allowlist)
        #expect(main.allowlistRules == [.init(pattern: "/bin/ls")])
        let none = OpenClawSystemRunApprovalPolicySnapshot(document: nil, agentId: "main")
        #expect(none.security == .full && none.ask == .off && none.askFallback == .deny && !none.autoAllowSkills)
    }

    @Test
    func delayedAuthorityToleratesAddedGrantsButNotRevocations() {
        func snapshot(_ rules: [OpenClawSystemRunApprovalPolicySnapshot.Rule], ask: OpenClawSystemRunApprovalPolicySnapshot.Ask = .onMiss)
            -> OpenClawSystemRunApprovalPolicySnapshot
        {
            OpenClawSystemRunApprovalPolicySnapshot(
                security: .allowlist, ask: ask, askFallback: .deny, autoAllowSkills: false, allowlistRules: rules)
        }
        let approved = snapshot([.init(pattern: "/bin/ls")])
        #expect(approved.isCurrent(snapshot([.init(pattern: "/bin/ls"), .init(pattern: "/bin/cat")])))
        #expect(approved.isCurrent(snapshot([.init(pattern: "/bin/ls", source: .allowAlways)])))
        #expect(!approved.isCurrent(snapshot([])))
        #expect(!approved.isCurrent(snapshot([.init(pattern: "/bin/ls")], ask: .always)))
        #expect(!snapshot([.init(pattern: "/bin/ls", source: .allowAlways)]).isCurrent(snapshot([.init(pattern: "/bin/ls")])))
    }

    @Test
    func systemRunParamsReadThePolicySnapshotFromTheForwardedPlan() throws {
        // Upstream gateway shape: the snapshot lives only inside systemRunPlan (pickSystemRunParams).
        let json = """
        {"command":["/bin/ls","-la"],"rawCommand":"/bin/ls -la","approved":true,"approvalDecision":"allow-once",
         "agentId":"main","systemRunPlan":{"argv":["/bin/ls","-la"],"cwd":null,"commandText":" /bin/ls -la ",
         "agentId":"main","sessionKey":"agent:main:main","policySnapshot":{"security":"allowlist","ask":"on-miss",
         "askFallback":"deny","autoAllowSkills":false,"allowlistRules":[{"pattern":"/bin/ls"}]}}}
        """
        let params = try JSONDecoder().decode(OpenClawSystemRunParams.self, from: Data(json.utf8))
        #expect(params.carriesDelayedApproval)
        let plan = try #require(try params.approvalPlan())
        #expect(plan.argv == ["/bin/ls", "-la"])
        #expect(plan.commandText == "/bin/ls -la")
        #expect(plan.cwd == nil)
        #expect(plan.policySnapshot == OpenClawSystemRunApprovalPolicySnapshot(
            security: .allowlist, ask: .onMiss, askFallback: .deny, autoAllowSkills: false,
            allowlistRules: [.init(pattern: "/bin/ls")]))

        // A present but malformed snapshot invalidates the plan instead of being dropped.
        let malformed = OpenClawSystemRunParams(
            command: ["/bin/ls"],
            approved: true,
            systemRunPlan: AnyCodable([
                "argv": AnyCodable([AnyCodable("/bin/ls")]),
                "commandText": AnyCodable("/bin/ls"),
                "policySnapshot": AnyCodable(["security": AnyCodable("everything")]),
            ]))
        #expect(throws: OpenClawNodeError.self) { try malformed.approvalPlan() }
        #expect(try OpenClawSystemRunParams(command: ["/bin/ls"]).approvalPlan() == nil)
        #expect(!OpenClawSystemRunParams(command: ["/bin/ls"], approvalDecision: "deny").carriesDelayedApproval)
        #expect(OpenClawSystemRunParams(command: ["/bin/ls"], approvalSource: "auto-review").carriesDelayedApproval)
        #expect(!OpenClawSystemRunParams(command: ["/bin/ls"], approvalSource: "ask-fallback").carriesDelayedApproval)
    }

    @Test
    func prepareResultEmbedsThePolicySnapshotInThePlan() throws {
        let document = ExecApprovalsDocument(
            version: 1,
            defaults: ExecApprovalsDefaultsDocument(security: .allowlist, ask: .always, askFallback: .deny),
            agents: ["ops": ExecApprovalsAgentDocument(allowlist: [ExecApprovalsAllowlistEntry(pattern: "/usr/bin/git")])])
        let result = OpenClawSystemRunPrepareResult(
            plan: OpenClawSystemRunApprovalPlan(argv: ["/usr/bin/git", "status"], commandText: "git status", agentId: "ops"),
            document: document)
        let expected = OpenClawSystemRunApprovalPolicySnapshot(document: document, agentId: "ops")
        #expect(result.plan.policySnapshot == expected)
        #expect(result.execPolicy == .init(security: .allowlist, ask: .always))

        let data = try JSONEncoder().encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plan = try #require(object["plan"] as? [String: Any])
        #expect((plan["policySnapshot"] as? [String: Any])?["security"] as? String == "allowlist")
        #expect(plan["cwd"] is NSNull, "upstream plans carry explicit nulls")
        #expect((object["allowAlwaysCoverage"] as? [String: Any])?["complete"] as? Bool == false)

        // What the gateway forwards back decodes to the same plan.
        let forwarded = try JSONDecoder().decode(AnyCodable.self, from: JSONSerialization.data(withJSONObject: plan))
        #expect(try OpenClawSystemRunApprovalPlan(wireValue: forwarded) == result.plan)
    }

    #if os(macOS)
    @Test
    func launchGuardDeniesChangedExecutablesAndPolicies() throws {
        let directory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("tool.sh")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: tool)
        let binding = try OpenClawSystemRunLaunchGuard.bind(executablePath: tool.path)
        #expect(binding.sha256 != nil, "a file in a writable directory is content-bound")
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(executablePath: tool.path, binding: binding) == nil)

        let alias = directory.appendingPathComponent("alias.sh")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tool)
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(executablePath: alias.path, binding: binding) == nil)

        try Data("#!/bin/sh\necho swapped\n".utf8).write(to: tool)
        let swapped = OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(executablePath: tool.path, binding: binding)
        #expect(swapped?.code == .systemRunDenied)
        #expect(swapped?.message.hasPrefix("SYSTEM_RUN_DENIED:") == true)

        let other = directory.appendingPathComponent("other.sh")
        try Data("#!/bin/sh\n".utf8).write(to: other)
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(executablePath: other.path, binding: binding)?.code
            == .systemRunDenied)

        let handler = OpenClawSystemExecApprovalsHandler(stateDirectoryURL: directory)
        let stored = try handler.apply(OpenClawSystemExecApprovalsSetParams(file: ExecApprovalsDocument(
            version: 1,
            defaults: ExecApprovalsDefaultsDocument(security: .allowlist, ask: .onMiss),
            agents: ["main": ExecApprovalsAgentDocument(allowlist: [ExecApprovalsAllowlistEntry(pattern: "/bin/ls")])])))
        let policy = OpenClawSystemRunApprovalPolicySnapshot(
            document: try ExecApprovalsSQLiteStore.read(stateDirectoryURL: directory)?.document,
            agentId: "main")
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            executablePath: "/bin/ls", binding: nil, policySnapshot: policy, agentId: "main",
            stateDirectoryURL: directory) == nil)
        _ = try handler.apply(OpenClawSystemExecApprovalsSetParams(
            file: ExecApprovalsDocument(version: 1, defaults: ExecApprovalsDefaultsDocument(security: .allowlist, ask: .onMiss)),
            baseHash: stored.hash))
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            executablePath: "/bin/ls", binding: nil, policySnapshot: policy, agentId: "main",
            stateDirectoryURL: directory)?.message == "SYSTEM_RUN_DENIED: exec approvals changed before execution")
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            executablePath: "/bin/ls", binding: nil, policySnapshot: policy)?.code == .systemRunDenied)

        // The params overload reads the forwarded plan and fails closed without a snapshot.
        let approvedWithoutSnapshot = OpenClawSystemRunParams(
            command: ["/bin/ls"],
            agentId: "main",
            approved: true,
            systemRunPlan: AnyCodable([
                "argv": AnyCodable([AnyCodable("/bin/ls")]),
                "commandText": AnyCodable("/bin/ls"),
            ]))
        let missing = OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            params: approvedWithoutSnapshot, executablePath: "/bin/ls", binding: nil, stateDirectoryURL: directory)
        #expect(missing?.code == .invalidRequest)
        #expect(missing?.message == "INVALID_REQUEST: delayed approval requires a prepared policy snapshot")
        var noPlan = approvedWithoutSnapshot
        noPlan.systemRunPlan = nil
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            params: noPlan, executablePath: "/bin/ls", binding: nil, stateDirectoryURL: directory)?.code == .invalidRequest)

        let planData = try JSONEncoder().encode(OpenClawSystemRunApprovalPlan(
            argv: ["/bin/ls"], commandText: "/bin/ls", agentId: "main", policySnapshot: policy))
        var approvedWithStaleSnapshot = approvedWithoutSnapshot
        approvedWithStaleSnapshot.systemRunPlan = try JSONDecoder().decode(AnyCodable.self, from: planData)
        let revoked = OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            params: approvedWithStaleSnapshot, executablePath: "/bin/ls", binding: nil, stateDirectoryURL: directory)
        #expect(revoked?.message == "SYSTEM_RUN_DENIED: exec approvals changed before execution")
        // Without delayed authority the run is policy-evaluated normally and needs no snapshot.
        #expect(OpenClawSystemRunLaunchGuard.verifyBeforeLaunch(
            params: OpenClawSystemRunParams(command: ["/bin/ls"]),
            executablePath: "/bin/ls",
            binding: nil,
            stateDirectoryURL: directory) == nil)

        #expect(OpenClawSystemRunLaunchGuard.sanitizedLaunchEnvironment([
            "PATH": "/usr/bin", "HOMEBREW_CURL_PATH": "/tmp/curl", "HOMEBREW_GIT_PATH": "/tmp/git",
        ]) == ["PATH": "/usr/bin"])
    }
    #endif
}
