import Foundation
import OpenClawKit
import Testing

@Suite("Gateway server startup facade")
struct GatewayServerStartupFacadeTests {
    private func stores() throws -> (SessionStore, FileCredentialStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclaw-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")),
            root)
    }

    private func call(_ server: GatewayServer, _ method: String) async -> ResponseFrame {
        await server.handle(RequestFrame(type: "req", id: UUID().uuidString, method: method, params: nil))
    }

    @Test
    func startedServersAttachTheRuntimeBehindStartupGating() async throws {
        let (sessionStore, credentialStore, root) = try self.stores()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = OpenClawSDK.shared.makeGatewayServer(sessionStore: sessionStore, credentialStore: credentialStore)
        #expect(await !plain.supportedMethods().contains("question.list"))

        let observed = StartupObservation()
        let server = try await OpenClawSDK.shared.startGatewayServer(
            sessionStore: sessionStore,
            credentialStore: credentialStore,
            options: OpenClawGatewayServerStartupOptions(gatedMethods: ["sessions.list"]),
            startup: { server in
                await observed.record(
                    pending: await server.isStartupPending(),
                    gatedError: await server.handle(RequestFrame(
                        type: "req", id: "1", method: "sessions.list", params: nil)).error?.isStartupUnavailable == true)
            })
        #expect(await observed.pending == true)
        #expect(await observed.gatedError == true)
        #expect(await server.isStartupPending() == false)
        #expect(await server.supportedMethods().contains("question.list"), "the runtime's handlers are registered")
        #expect(await self.call(server, "sessions.list").ok)
    }

    @Test
    func startupCanBeLeftUngatedAndUnattached() async throws {
        let (sessionStore, credentialStore, root) = try self.stores()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await OpenClawSDK.shared.startGatewayServer(
            sessionStore: sessionStore,
            credentialStore: credentialStore,
            options: OpenClawGatewayServerStartupOptions(attachRuntime: false, gatesStartup: false),
            startup: { server in
                #expect(await server.isStartupPending() == false)
            })
        #expect(await !server.supportedMethods().contains("question.list"))
    }
}

private actor StartupObservation {
    private(set) var pending: Bool?
    private(set) var gatedError: Bool?

    func record(pending: Bool, gatedError: Bool) {
        self.pending = pending
        self.gatedError = gatedError
    }
}
