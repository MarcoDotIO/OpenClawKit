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
    func systemRunParamsCarryThePolicySnapshot() throws {
        let policy = OpenClawSystemRunApprovalPolicySnapshot(
            security: .allowlist, ask: .onMiss, askFallback: .deny, autoAllowSkills: false,
            allowlistRules: [.init(pattern: "/bin/ls")])
        let params = OpenClawSystemRunParams(command: ["/bin/ls"], approved: true, policySnapshot: policy)
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["policySnapshot"] as? [String: Any])?["security"] as? String == "allowlist")
        #expect(try JSONDecoder().decode(OpenClawSystemRunParams.self, from: data).policySnapshot == policy)
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

        #expect(OpenClawSystemRunLaunchGuard.sanitizedLaunchEnvironment([
            "PATH": "/usr/bin", "HOMEBREW_CURL_PATH": "/tmp/curl", "HOMEBREW_GIT_PATH": "/tmp/git",
        ]) == ["PATH": "/usr/bin"])
    }
    #endif
}
