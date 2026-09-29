import Foundation
import OpenClawAppIntents
import OpenClawKit
import Testing

@Suite("App Intents cancellation cleanup")
struct OpenClawAppIntentsCancellationTests {
    @Test
    func intentAbortHelperSendsChatAbortFromACancelledCaller() async throws {
        let requester = FakeIntentGatewayRequester()
        await requester.respond(to: "chat.send", json: #"{"runId":"r-cancel"}"#)
        let host = GatewayOpenClawIntentHost(requester: requester)
        _ = try await host.send(prompt: "long task", sessionKey: "agent:main:main", agentId: nil)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await OpenClawIntentActions.abort(sessionKey: "agent:main:main", host: host)
        }
        await cancelled.value

        let abort = try #require(await requester.requests(for: "chat.abort").first)
        #expect(abort.params["runId"]?.stringValue == "r-cancel")
        #expect(!abort.wasCancelled)
    }

    @Test
    func gatewayChannelIsTheSharedIntentRequestSeam() throws {
        // OpenClawIntentGatewayRequesting is OpenClawKit's GatewayRequestSending, so the channel
        // conforms without an App Intents-specific extension.
        let channel = GatewayChannelActor(url: try #require(URL(string: "ws://127.0.0.1:18789")), token: nil)
        let requester: any OpenClawIntentGatewayRequesting = channel
        let shared: any GatewayRequestSending = requester
        #expect(shared is GatewayChannelActor)
    }
}
