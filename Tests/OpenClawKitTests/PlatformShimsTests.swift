import Foundation
import Testing
@testable import OpenClawCore

@Suite("Platform shims")
struct PlatformShimsTests {
    @Test
    func sha256HexIsStable() {
        let value = OpenClawCrypto.sha256Hex(Data("openclaw".utf8))
        #expect(value == "96a4bc2602655473120fcc571ee3d8cfe5f8801f8038ccc06323d305e323331c")
    }

    @Test
    func hmacProducesBytes() {
        let output = OpenClawCrypto.hmacSHA256(key: Data("k".utf8), data: Data("v".utf8))
        #expect(output.isEmpty == false)
    }

    @Test
    func normalizeFingerprintDropsNonHexCharacters() {
        let normalized = OpenClawSecurity.normalizeFingerprint("SHA-256: AA:bb-12")
        #expect(normalized == "aabb12")
    }

    @Test
    func fileSystemRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try OpenClawFileSystem.ensureDirectory(dir)

        let file = dir.appendingPathComponent("data.txt", isDirectory: false)
        try OpenClawFileSystem.writeData(Data("hello".utf8), to: file)
        let data = try OpenClawFileSystem.readData(file)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test
    func processRunnerRunsCommand() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(["/bin/echo", "ok"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("ok"))
    }

    @Test
    func processRunnerReturnsAfterNonZeroExitWithStderrOnlyOutput() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(["/bin/sh", "-c", "echo failing 1>&2; exit 2"])
        #expect(result.exitCode == 2)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.stderr.contains("failing"))
    }
}
