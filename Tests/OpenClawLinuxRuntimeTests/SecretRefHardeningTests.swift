import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("SecretRef file and exec provider hardening", .serialized)
struct SecretRefHardeningTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-secret-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL, mode: Int) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private func violationCode(_ body: () throws -> Void) -> SecretPathSecurity.Violation.Code? {
        do {
            try body()
            return nil
        } catch let violation as SecretPathSecurity.Violation {
            return violation.code
        } catch {
            return nil
        }
    }

    // MARK: File providers

    @Test
    func secretFilesMustBePrivateRegularSingleLinkFiles() throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("secrets.json")
        try self.write(#"{"k": "v"}"#, to: file, mode: 0o600)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureSecretFile(file.path, label: "l") } == nil)

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: file.path)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureSecretFile(file.path, label: "l") } == .insecurePermissions)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)

        let alias = directory.appendingPathComponent("alias.json")
        try FileManager.default.linkItem(at: file, to: alias)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureSecretFile(file.path, label: "l") } == .hardlink)
        try FileManager.default.removeItem(at: alias)

        let symlink = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureSecretFile(symlink.path, label: "l") } == .symlink)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureSecretFile(directory.path, label: "l") } == .notRegularFile)
        #expect(self.violationCode {
            try SecretPathSecurity.assertSecureSecretFile(directory.appendingPathComponent("missing").path, label: "l")
        } == .unreadable)
    }

    @Test
    func foreignOwnersAreRejected() {
        let facts = SecretPathSecurity.FileFacts(type: SecretPathSecurity.FileFacts.regularFile, permissions: 0o600, linkCount: 1, ownerUID: 4_242)
        #expect(self.violationCode {
            try SecretPathSecurity.checkSecretFile(facts, path: "/x", label: "l", currentUID: 501)
        } == .foreignOwner)
        #expect(self.violationCode {
            try SecretPathSecurity.checkExecCommand(facts, path: "/x", label: "l", trustedDirs: [], currentUID: 501)
        } == .foreignOwner)
        #expect(self.violationCode {
            try SecretPathSecurity.checkSecretFile(facts, path: "/x", label: "l", currentUID: 4_242)
        } == nil)
    }

    @Test
    func resolverRefusesInsecureSecretFiles() async throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token.txt")
        try self.write("\u{FEFF}  padded-token  \r\n", to: file, mode: 0o644)
        let config = SecretsConfig(providers: ["mounted": .file(FileSecretProviderConfig(path: file.path, mode: .singleValue))])
        let resolver = DefaultSecretRefResolver(environment: [:])
        let ref = SecretRef(source: .file, provider: "mounted", id: "value")
        do {
            _ = try await resolver.resolve(ref, config: config)
            Issue.record("expected the world-readable file to be refused")
        } catch {
            #expect(error.localizedDescription.contains("permissions are too open"))
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
        // singleValue strips the BOM and exactly one trailing newline, like upstream.
        #expect(try await resolver.resolve(ref, config: config) == "  padded-token  ")
    }

    // MARK: Exec providers

    @Test
    func execCommandsMustBeTrustedPrivateRegularFiles() throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("resolver.sh")
        try self.write("#!/bin/sh\nexit 0\n", to: script, mode: 0o700)
        let label = "secrets.providers.vault.command"

        #expect(try SecretPathSecurity.assertSecureExecCommand(script.path, label: label, trustedDirs: [directory.path]) == script.standardizedFileURL.path)
        #expect(self.violationCode {
            try SecretPathSecurity.assertSecureExecCommand("relative/resolver.sh", label: label)
        } == .notAbsolute)
        #expect(self.violationCode {
            try SecretPathSecurity.assertSecureExecCommand(script.path, label: label, trustedDirs: ["/opt/trusted"])
        } == .outsideTrustedDirs)

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o770)], ofItemAtPath: script.path)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureExecCommand(script.path, label: label) } == .insecurePermissions)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: script.path)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureExecCommand(script.path, label: label) } == nil)

        // Symlinks are refused before the trusted-directory check.
        let symlink = directory.appendingPathComponent("resolver-link.sh")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: script)
        #expect(self.violationCode {
            try SecretPathSecurity.assertSecureExecCommand(symlink.path, label: label, trustedDirs: [directory.path])
        } == .symlink)
        #expect(self.violationCode { try SecretPathSecurity.assertSecureExecCommand(directory.path, label: label) } == .notRegularFile)
    }

    #if os(macOS) || os(Linux)
    @Test
    func retiredSymlinkOptOutStaysFailClosed() async throws {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("resolver.sh")
        try self.write("#!/bin/sh\ncat >/dev/null\nprintf '{\"protocolVersion\":1,\"values\":{\"k\":\"v\"}}'\n", to: script, mode: 0o700)
        let symlink = directory.appendingPathComponent("resolver-link.sh")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: script)
        let config = SecretsConfig(providers: [
            "vault": .exec(ExecSecretProviderConfig(command: symlink.path, allowInsecurePath: true, allowSymlinkCommand: true)),
        ])
        let resolver = DefaultSecretRefResolver(environment: [:])
        do {
            _ = try await resolver.resolve(SecretRef(source: .exec, provider: "vault", id: "k"), config: config)
            Issue.record("expected the symlinked command to be refused")
        } catch {
            #expect(error.localizedDescription.contains("must not be a symlink"))
        }
        let direct = SecretsConfig(providers: ["vault": .exec(ExecSecretProviderConfig(command: script.path))])
        #expect(try await resolver.resolve(SecretRef(source: .exec, provider: "vault", id: "k"), config: direct) == "v")
    }
    #endif

    @Test
    func trustedDirectoryContainmentIsLexicalAndBoundaryAware() {
        #expect(SecretPathSecurity.isPath("/opt/bin/tool", inside: "/opt/bin"))
        #expect(SecretPathSecurity.isPath("/opt/bin/tool", inside: "/opt/bin/"))
        #expect(!SecretPathSecurity.isPath("/opt/binary/tool", inside: "/opt/bin"))
        #expect(SecretPathSecurity.isPath("/anything", inside: "/"))
    }

    @Test
    func channelSecretResolverCanUseTheHardenedSecretRefResolver() async throws {
        let resolver = ChannelSecretResolver.usingSecretRefResolver(
            DefaultSecretRefResolver(environment: ["BOT_TOKEN": "from-env"]),
            secrets: SecretsConfig()
        )
        #expect(try await resolver.resolve(.ref(SecretRef(source: .env, id: "BOT_TOKEN"))) == "from-env")
        #expect(try await resolver.resolve(.string("plain")) == "plain")
    }

    #if os(macOS) || os(Linux)
    // MARK: Exec provider process limits

    private func runExec(
        _ script: String,
        timeoutMs: Int = 3_000,
        noOutputTimeoutMs: Int? = nil,
        maxOutputBytes: Int = 1_048_576
    ) async throws -> (result: Result<Data, Error>, seconds: Double) {
        let directory = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("provider.sh")
        try self.write("#!/bin/sh\n" + script + "\n", to: url, mode: 0o700)
        let started = Date()
        let limits = ExecSecretProcess.Limits(
            providerName: "vault",
            timeoutMs: timeoutMs,
            noOutputTimeoutMs: noOutputTimeoutMs ?? timeoutMs,
            maxOutputBytes: maxOutputBytes
        )
        let result: Result<Data, Error>
        do {
            result = .success(try await ExecSecretProcess.run(command: url.path, arguments: [], environment: [:], input: Data("{}".utf8), limits: limits))
        } catch {
            result = .failure(error)
        }
        return (result, Date().timeIntervalSince(started))
    }

    private func message(_ result: Result<Data, Error>) -> String {
        if case .failure(let error) = result { return String(describing: error) }
        return ""
    }

    @Test
    func execProviderReturnsWhenABackgroundedHelperKeepsStdoutOpen() async throws {
        let run = try await self.runExec("cat >/dev/null\necho '{\"protocolVersion\":1,\"values\":{\"k\":\"v\"}}'\nsleep 3 &\nexit 0")
        #expect(run.seconds < 5)
        let output = try run.result.get()
        #expect(try DefaultSecretRefResolver.parseExecResponse(output, id: "k", providerName: "vault", jsonOnly: true) == "v")
    }

    @Test
    func execProviderTimeoutKillsATermTrappingProcessTree() async throws {
        let run = try await self.runExec("trap '' TERM\nsleep 20 &\nsleep 20", timeoutMs: 300)
        #expect(run.seconds < 5)
        #expect(self.message(run.result).contains("timed out after 300ms"))
    }

    @Test
    func execProviderOutputIsCappedWhileReading() async throws {
        let run = try await self.runExec("exec yes", maxOutputBytes: 4_096)
        #expect(run.seconds < 5)
        #expect(self.message(run.result).contains("exceeded maxOutputBytes (4096)"))
    }

    @Test
    func execProviderNoOutputTimeoutFiresBeforeTheOverallTimeout() async throws {
        let run = try await self.runExec("sleep 20", timeoutMs: 10_000, noOutputTimeoutMs: 200)
        #expect(run.seconds < 5)
        #expect(self.message(run.result).contains("produced no output for 200ms"))
    }

    @Test
    func execProviderPollWaitNeverUnderflowsWhenAnEventIsOverdue() {
        // While stdout is drained after the child exits, the deadline and the no-output timer may
        // already lie in the past; the wait must clamp instead of trapping on UInt64 underflow.
        #expect(ExecSecretProcess.pollWaitMs(now: 5_000_000_000, nextEvent: 1_000_000_000) == 1)
        #expect(ExecSecretProcess.pollWaitMs(now: 5_000_000_000, nextEvent: 5_000_000_000) == 1)
        #expect(ExecSecretProcess.pollWaitMs(now: 5_000_000_000, nextEvent: 5_020_000_000) == 20)
        #expect(ExecSecretProcess.pollWaitMs(now: 0, nextEvent: UInt64.max) == 50)
    }

    @Test
    func execProviderThatExitsAtTheEndOfItsSilentWindowSucceeds() async throws {
        // Exits right as the no-output window closes, so the exit is noticed with the timer overdue.
        for _ in 0..<3 {
            let run = try await self.runExec(
                "cat >/dev/null\necho '{\"protocolVersion\":1,\"values\":{\"k\":\"v\"}}'\nsleep 0.29\nexit 0",
                timeoutMs: 3_000,
                noOutputTimeoutMs: 300
            )
            if case .failure(let error) = run.result {
                // Losing the race to the no-output timer is allowed; crashing is not.
                #expect(String(describing: error).contains("produced no output for 300ms"))
            } else {
                #expect(try DefaultSecretRefResolver.parseExecResponse(try run.result.get(), id: "k", providerName: "vault", jsonOnly: true) == "v")
            }
        }
    }

    @Test
    func execProviderThatNeverReadsStdinDoesNotRaiseSIGPIPE() async throws {
        let run = try await self.runExec("exec 0<&-\necho '{\"protocolVersion\":1,\"values\":{\"k\":\"v\"}}'")
        #expect(try DefaultSecretRefResolver.parseExecResponse(try run.result.get(), id: "k", providerName: "vault", jsonOnly: true) == "v")
        let failing = try await self.runExec("exit 3")
        #expect(self.message(failing.result).contains("exited with status 3"))
    }
    #endif
}
