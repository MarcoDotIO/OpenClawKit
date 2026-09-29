import Combine
import OpenClawChatUI
import OpenClawKit
import SwiftUI

/// Connects to a remote OpenClaw gateway as an operator and hosts the SDK chat UI over it.
///
/// Uses `OpenClawGatewaySessionChatTransport` (OpenClawChatUI), the ready-made chat transport over
/// one `GatewayNodeSession`. Every queued or durable chat operation captures a route lease, so work
/// suspended behind a reconnect is cancelled instead of being sent to another gateway.
@MainActor
final class GatewayChatController: ObservableObject {
    @Published var gatewayURL: String = ""
    @Published var token: String = ""
    @Published private(set) var status: String = "Not connected"
    @Published private(set) var viewModel: OpenClawChatViewModel?

    private let session = GatewayNodeSession()

    /// Validates the URL with the SDK transport-security policy, connects and builds the chat model.
    func connect() async {
        let trimmedURL = self.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            self.status = "Enter a ws:// or wss:// gateway URL."
            return
        }
        switch GatewayTransportSecurityPolicy.evaluate(url: url) {
        case .rejectNonRoutable:
            self.status = "That host is not a valid gateway address."
            return
        case .requireTLS:
            self.status = "Plaintext ws:// is only allowed on the local network; use wss://."
            return
        case .ok, .warnCleartextLAN:
            break
        }

        // The stable gateway id scopes device tokens and chat route leases to this gateway.
        let gatewayID = url.absoluteString
        var options = GatewayConnectOptions.defaultOperator(displayName: "OpenClaw iOS Example")
        options.deviceAuthGatewayID = gatewayID
        let trimmedToken = self.token.trimmingCharacters(in: .whitespacesAndNewlines)

        self.status = "Connecting..."
        do {
            try await self.session.connect(
                url: url,
                token: trimmedToken.isEmpty ? nil : trimmedToken,
                connectOptions: options,
                sessionBox: nil,
                onConnected: { [weak self] in
                    await self?.updateStatus("Connected")
                },
                onDisconnected: { [weak self] reason in
                    await self?.updateStatus("Disconnected: \(reason)")
                },
                onInvoke: { request in
                    // Operator connections do not serve node commands.
                    BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: operator session")
                    )
                }
            )
            let transport = OpenClawGatewaySessionChatTransport(
                gateway: self.session,
                gatewayStableID: gatewayID
            )
            self.viewModel = OpenClawChatViewModel(sessionKey: "main", transport: transport)
        } catch {
            self.status = "Connection failed: \(error.localizedDescription)"
        }
    }

    /// Closes the gateway connection and drops the chat model.
    func disconnect() async {
        self.viewModel = nil
        await self.session.disconnect()
        self.status = "Not connected"
    }

    private func updateStatus(_ status: String) {
        self.status = status
    }
}

/// Remote gateway chat tab: connection form plus `OpenClawChatView`.
struct GatewayChatView: View {
    @StateObject private var controller = GatewayChatController()

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel = controller.viewModel {
                    OpenClawChatView(viewModel: viewModel)
                } else {
                    Form {
                        Section {
                            TextField("wss://gateway.example.com", text: $controller.gatewayURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            SecureField("Gateway token (optional)", text: $controller.token)
                            Button("Connect") {
                                Task { await controller.connect() }
                            }
                        } header: {
                            Text("Remote Gateway")
                        } footer: {
                            Text(controller.status)
                        }
                    }
                }
            }
            .navigationTitle("Gateway Chat")
            .toolbar {
                if controller.viewModel != nil {
                    Button("Disconnect") {
                        Task { await controller.disconnect() }
                    }
                }
            }
        }
    }
}

#Preview {
    GatewayChatView()
}
