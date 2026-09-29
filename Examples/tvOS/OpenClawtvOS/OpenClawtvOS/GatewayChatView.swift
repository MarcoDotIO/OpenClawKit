import Combine
import OpenClawChatUI
import OpenClawKit
import SwiftUI

/// Connects to a remote OpenClaw gateway as an operator and drives the SDK chat view model over it.
///
/// On tvOS OpenClawChatUI ships the non-UI chat core only (`OpenClawChatViewModel`, transports and
/// models), so this example renders its own transcript on top of `OpenClawChatViewModel` and
/// `OpenClawGatewaySessionChatTransport`.
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

        let gatewayID = url.absoluteString
        var options = GatewayConnectOptions.defaultOperator(displayName: "OpenClaw tvOS Example")
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
            let viewModel = OpenClawChatViewModel(sessionKey: "main", transport: transport)
            viewModel.load()
            self.viewModel = viewModel
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

/// Remote gateway chat tab.
struct GatewayChatView: View {
    @StateObject private var controller = GatewayChatController()

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel = controller.viewModel {
                    GatewayTranscriptView(viewModel: viewModel) {
                        Task { await controller.disconnect() }
                    }
                } else {
                    Form {
                        Section {
                            TextField("wss://gateway.example.com", text: $controller.gatewayURL)
                                .autocorrectionDisabled()
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
        }
    }
}

/// Minimal transcript over `OpenClawChatViewModel` (tvOS has no SDK chat views).
struct GatewayTranscriptView: View {
    @Bindable var viewModel: OpenClawChatViewModel
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            List(viewModel.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.role.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.content.compactMap(\.text).joined(separator: "\n"))
                }
            }
            HStack {
                TextField("Message", text: $viewModel.input)
                Button("Send") {
                    viewModel.send()
                }
                .disabled(viewModel.isSending)
                Button("Disconnect", role: .destructive, action: onDisconnect)
            }
            if let errorText = viewModel.errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
