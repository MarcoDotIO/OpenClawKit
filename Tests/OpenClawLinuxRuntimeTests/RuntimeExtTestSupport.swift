import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Shared helpers for the runtime extension (skills, MCP, memory, plugins, cron) test suites.
enum RuntimeExtTestSupport {
    static func temporaryDirectory(_ label: String = "runtime-ext") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeSkill(root: URL, directory: String, contents: String) throws -> URL {
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func makeGatewayServer(root: URL) -> GatewayServer {
        GatewayServer(
            sessionStore: SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            secretVault: GatewaySecretVault(credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json")))
        )
    }

    static func call(
        _ server: GatewayServer,
        _ method: String,
        params: [String: AnyCodable]? = nil,
        connection: GatewayConnectionContext = .inProcess
    ) async -> ResponseFrame {
        let frame = RequestFrame(type: "req", id: UUID().uuidString, method: method, params: params.map { AnyCodable($0) })
        return await server.handle(frame, connection: connection)
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable?) throws -> T {
        let data = try JSONEncoder().encode(payload ?? AnyCodable.nullValue)
        return try JSONDecoder().decode(type, from: data)
    }

    static let nodeConnection = GatewayConnectionContext(connectionID: "node-1", role: "node", scopes: [])
}
