import Foundation
import Testing
@testable import OpenClawKit

@Suite("Gateway transport")
struct GatewayTransportE2ETests {
    actor ScriptedSocket: GatewaySocket {
        private let connectError: GatewayTransportError?
        private let sendError: GatewayTransportError?
        private let responseBuilder: @Sendable (RequestFrame) throws -> [String]
        private var open = false
        private var queue: [Result<String, Error>] = []
        private var waiters: [CheckedContinuation<String, Error>] = []

        init(
            connectError: GatewayTransportError? = nil,
            sendError: GatewayTransportError? = nil,
            responseBuilder: @escaping @Sendable (RequestFrame) throws -> [String] = { _ in [] }
        ) {
            self.connectError = connectError
            self.sendError = sendError
            self.responseBuilder = responseBuilder
        }

        func connect(url _: URL) async throws {
            if let connectError {
                throw connectError
            }
            self.open = true
        }

        func send(text: String) async throws {
            guard self.open else {
                throw GatewayTransportError.notConnected
            }
            if let sendError {
                throw sendError
            }
            let request = try JSONDecoder().decode(RequestFrame.self, from: Data(text.utf8))
            for raw in try self.responseBuilder(request) {
                self.enqueue(.success(raw))
            }
        }

        func receive() async throws -> String {
            if let next = self.queue.first {
                self.queue.removeFirst()
                return try next.get()
            }
            guard self.open else {
                throw GatewayTransportError.notConnected
            }
            return try await withCheckedThrowingContinuation { continuation in
                self.waiters.append(continuation)
            }
        }

        func close() async {
            self.open = false
            let pending = self.waiters
            self.waiters.removeAll()
            for waiter in pending {
                waiter.resume(throwing: GatewayTransportError.notConnected)
            }
        }

        func enqueue(raw: String) {
            self.enqueue(.success(raw))
        }

        func enqueue(error: Error) {
            self.enqueue(.failure(error))
        }

        private func enqueue(_ result: Result<String, Error>) {
            if let waiter = self.waiters.first {
                self.waiters.removeFirst()
                switch result {
                case .success(let raw):
                    waiter.resume(returning: raw)
                case .failure(let error):
                    waiter.resume(throwing: error)
                }
                return
            }
            self.queue.append(result)
        }
    }

    final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []

        func record(_ event: String) {
            self.lock.lock()
            self.events.append(event)
            self.lock.unlock()
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            self.lock.lock()
            self.value += 1
            self.lock.unlock()
        }

        func get() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    actor NoTickSocket: GatewaySocket {
        func connect(url _: URL) async throws {}
        func send(text _: String) async throws {}
        func receive() async throws -> String {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw GatewayTransportError.notConnected
        }

        func close() async {}
    }

    actor ConnectFailureSocket: GatewaySocket {
        func connect(url _: URL) async throws {
            throw GatewayTransportError.invalidFrame("synthetic reconnect failure")
        }

        func send(text _: String) async throws {}

        func receive() async throws -> String {
            throw GatewayTransportError.notConnected
        }

        func close() async {}
    }

    @Test
    func connectAndRequestRoundTrip() async throws {
        let client = GatewayClient()
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        let response = try await client.send(method: "connect")
        #expect(response.ok == true)
        await client.disconnect()
    }

    @Test
    func transportErrorsHaveStableDescriptions() {
        let cases: [GatewayTransportError] = [
            .notConnected,
            .requestTimeout(requestID: "req-1"),
            .invalidFrame("broken"),
            .tlsFingerprintMismatch,
            .remote(ErrorShape(code: .unavailable, message: "remote failed")),
        ]

        let descriptions = cases.compactMap(\.errorDescription)
        #expect(descriptions.count == cases.count)
        #expect(descriptions.contains("Gateway is not connected"))
        #expect(descriptions.contains(where: { $0.contains("req-1") }))
        #expect(descriptions.contains(where: { $0.contains("broken") }))
        #expect(descriptions.contains(where: { $0.lowercased().contains("fingerprint") }))
        #expect(descriptions.contains(where: { $0.contains("remote failed") }))
    }

    @Test
    func tlsFingerprintMismatchFailsConnect() async {
        let client = GatewayClient(
            tls: GatewayTLSSettings(expectedFingerprint: "deadbeef", required: true)
        )

        do {
            try await client.connect(
                to: GatewayEndpoint(
                    url: URL(string: "wss://127.0.0.1:18789")!,
                    serverFingerprint: "cafebabe"
                )
            )
            Issue.record("Expected TLS mismatch error")
        } catch {
            #expect(String(describing: error).lowercased().contains("fingerprint"))
        }
    }

    @Test
    func tlsValidationRequiresFingerprintWhenSecureEndpointIsPinned() async {
        let client = GatewayClient(
            tls: GatewayTLSSettings(required: true)
        )

        do {
            try await client.connect(to: GatewayEndpoint(url: URL(string: "wss://127.0.0.1:18789")!))
            Issue.record("Expected TLS fingerprint requirement failure")
        } catch {
            #expect(String(describing: error).lowercased().contains("fingerprint"))
        }
    }

    @Test
    func tlsValidationAllowsSecureEndpointsWhenPinningIsOptional() async throws {
        let client = GatewayClient()
        try await client.connect(to: GatewayEndpoint(url: URL(string: "wss://127.0.0.1:18789")!))
        #expect(await client.isConnected())
        await client.disconnect()
    }

    @Test
    func tickTimeoutTriggersReconnect() async throws {
        let counter = Counter()
        let client = GatewayClient(
            socketFactory: {
                counter.increment()
                return NoTickSocket()
            },
            tickIntervalMs: 20,
            initialReconnectBackoffMs: 25
        )

        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(counter.get() > 1)
        await client.disconnect()
    }

    @Test
    func disconnectStopsFurtherReconnectAttempts() async throws {
        let counter = Counter()
        let client = GatewayClient(
            socketFactory: {
                counter.increment()
                return NoTickSocket()
            },
            tickIntervalMs: 20,
            initialReconnectBackoffMs: 25
        )

        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        try await Task.sleep(nanoseconds: 220_000_000)
        await client.disconnect()

        // Allow cancellation to settle, then verify no further reconnect attempts occur.
        try await Task.sleep(nanoseconds: 80_000_000)
        let baseline = counter.get()
        try await Task.sleep(nanoseconds: 220_000_000)
        #expect(counter.get() == baseline)
    }

    @Test
    func reconnectFailureSchedulesAnotherAttempt() async throws {
        let counter = Counter()
        let client = GatewayClient(
            socketFactory: {
                let attempt = counter.get()
                counter.increment()
                if attempt == 0 {
                    return NoTickSocket()
                }
                if attempt == 1 {
                    return ConnectFailureSocket()
                }
                return NoTickSocket()
            },
            tickIntervalMs: 20,
            initialReconnectBackoffMs: 25
        )

        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        try await Task.sleep(nanoseconds: 220_000_000)
        #expect(counter.get() > 2)
        await client.disconnect()
    }

    @Test
    func sendRejectsDisconnectedClientAndLoopbackCoversQueuedFrames() async throws {
        let client = GatewayClient()
        do {
            let _ = try await client.send(method: "connect")
            Issue.record("Expected disconnected gateway send to fail")
        } catch let error as GatewayTransportError {
            switch error {
            case .notConnected:
                break
            default:
                Issue.record("Expected notConnected transport error")
            }
        }

        let socket = LoopbackGatewaySocket()
        try await socket.connect(url: URL(string: "ws://127.0.0.1:18789")!)
        let rawRequest = String(
            decoding: try JSONEncoder().encode(
                RequestFrame(type: "req", id: "queued", method: "connect", params: AnyCodable([String: AnyCodable]()))
            ),
            as: UTF8.self
        )
        try await socket.send(text: rawRequest)
        let queued = try await socket.receive()
        let frame = try JSONDecoder().decode(ResponseFrame.self, from: Data(queued.utf8))
        #expect(frame.id == "queued")
        #expect(frame.ok == true)

        await socket.close()

        do {
            try await socket.send(text: rawRequest)
            Issue.record("Expected closed loopback send to fail")
        } catch {
            #expect(String(describing: error).lowercased().contains("connect"))
        }

        do {
            let _ = try await socket.receive()
            Issue.record("Expected closed loopback receive to fail")
        } catch {
            #expect(String(describing: error).lowercased().contains("closed"))
        }
    }

    @Test
    func typedRequestsCoverEventsTimeoutsFailuresAndMalformedFrames() async throws {
        let recorder = EventRecorder()
        let socket = ScriptedSocket { request in
            [
                String(
                    decoding: try JSONEncoder().encode(
                        ResponseFrame(
                            type: "res",
                            id: request.id,
                            ok: true,
                            payload: AnyCodable(["status": AnyCodable("accepted")]),
                            error: nil
                        )
                    ),
                    as: UTF8.self
                ),
            ]
        }
        let client = GatewayClient(
            socketFactory: { socket },
            tickIntervalMs: 40,
            initialReconnectBackoffMs: 40,
            onEvent: { event in
                recorder.record(event.event)
            }
        )
        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))

        await socket.enqueue(raw: String(
            decoding: try JSONEncoder().encode(
                EventFrame(type: "event", event: "tick", payload: AnyCodable(["kind": AnyCodable("heartbeat")]), seq: 1)
            ),
            as: UTF8.self
        ))
        await socket.enqueue(raw: String(
            decoding: try JSONEncoder().encode(
                EventFrame(type: "event", event: "notice", payload: AnyCodable(["kind": AnyCodable("message")]), seq: 2)
            ),
            as: UTF8.self
        ))
        await socket.enqueue(raw: String(
            decoding: try JSONEncoder().encode(
                RequestFrame(type: "req", id: "noop", method: "ignored", params: AnyCodable([String: AnyCodable]()))
            ),
            as: UTF8.self
        ))
        await socket.enqueue(raw: "{")

        let response = try await client.send(method: "connect")
        #expect(response.ok == true)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.events.contains("tick"))
        #expect(recorder.events.contains("notice"))

        do {
            let _: GatewayModelsListResult = try await client.request("models.list", params: [1, 2, 3])
            Issue.record("Expected typed request params object validation failure")
        } catch let error as GatewayTransportError {
            switch error {
            case .invalidFrame(let message):
                #expect(message.contains("object"))
            default:
                Issue.record("Expected invalidFrame error for non-object params")
            }
        }

        let sendFailureSocket = ScriptedSocket(sendError: .invalidFrame("synthetic send failure"))
        let sendFailureClient = GatewayClient(socketFactory: { sendFailureSocket })
        try await sendFailureClient.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        do {
            let _ = try await sendFailureClient.send(method: "connect", timeoutMs: 100)
            Issue.record("Expected send failure to surface through pending request")
        } catch let error as GatewayTransportError {
            switch error {
            case .invalidFrame(let detail):
                #expect(detail.contains("synthetic send failure"))
            default:
                Issue.record("Expected invalidFrame send failure")
            }
        }
        await sendFailureClient.disconnect()

        let timeoutSocket = ScriptedSocket()
        let timeoutClient = GatewayClient(socketFactory: { timeoutSocket })
        try await timeoutClient.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        do {
            let _ = try await timeoutClient.send(method: "connect", timeoutMs: 5)
            Issue.record("Expected request timeout")
        } catch let error as GatewayTransportError {
            switch error {
            case .requestTimeout:
                break
            default:
                Issue.record("Expected request timeout transport error")
            }
        }

        let pendingTask = Task {
            try await timeoutClient.send(method: "connect", timeoutMs: 5_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await timeoutClient.disconnect()
        do {
            let _ = try await pendingTask.value
            Issue.record("Expected pending request to fail when disconnect drains pending continuations")
        } catch let error as GatewayTransportError {
            switch error {
            case .notConnected:
                break
            default:
                Issue.record("Expected disconnect to fail pending requests with notConnected")
            }
        }

        let failedResponseSocket = ScriptedSocket { request in
            [
                String(
                    decoding: try JSONEncoder().encode(
                        ResponseFrame(type: "res", id: request.id, ok: false, payload: nil, error: nil)
                    ),
                    as: UTF8.self
                ),
            ]
        }
        let failedResponseClient = GatewayClient(socketFactory: { failedResponseSocket })
        try await failedResponseClient.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        do {
            let _: GatewayModelsListResult = try await failedResponseClient.request("models.list")
            Issue.record("Expected invalid frame for failed response without error payload")
        } catch let error as GatewayTransportError {
            switch error {
            case .invalidFrame(let detail):
                #expect(detail.contains("without an error payload"))
            default:
                Issue.record("Expected invalidFrame error for malformed failed response")
            }
        }
        await failedResponseClient.disconnect()
    }

    @Test
    func typedRequestsSurfaceRemoteErrorsFromServerBackedLoopback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-gateway-transport-errors", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = GatewayServer(
            sessionStore: SessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            secretVault: GatewaySecretVault(
                credentialStore: FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
            )
        )
        let client = GatewayClient(
            socketFactory: { LoopbackGatewaySocket(server: server) }
        )

        try await client.connect(to: GatewayEndpoint(url: URL(string: "ws://127.0.0.1:18789")!))
        defer {
            Task {
                await client.disconnect()
            }
        }

        do {
            let _: GatewayModelsListResult = try await client.request("models.list")
            Issue.record("Expected remote unavailable error")
        } catch let error as GatewayTransportError {
            switch error {
            case .remote(let shape):
                #expect(shape.code == .unavailable)
            default:
                Issue.record("Expected remote gateway error")
            }
        }
    }
}
