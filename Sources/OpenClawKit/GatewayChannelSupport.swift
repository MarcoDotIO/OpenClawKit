import CryptoKit
import Foundation
import OpenClawProtocol

/// Why a ``GatewayChannelActor`` stopped reconnecting automatically.
public enum GatewayReconnectPauseReason: String, Sendable, Equatable {
    /// A non-recoverable auth rejection (bad credentials, pairing required, rate limited, ...).
    /// `AUTH_RATE_LIMITED` with a `retryAfterMs` hint resumes once after that delay.
    case authFailure
    /// The gateway certificate no longer matches the stored pin; see
    /// ``GatewayChannelActor/pendingTLSPinRotationRequest()``.
    case tlsPinMismatch
}

/// Reads an integer from a gateway detail value: integers, integral doubles, or numeric strings.
func gatewayIntValue(_ value: OpenClawProtocol.AnyCodable?) -> Int? {
    guard let value else { return nil }
    switch value.value {
    case let .int(int):
        return int
    case let .double(double):
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    case let .string(string):
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

/// Flattens an upstream `ErrorShape` into the `GatewayResponseError.details` dictionary.
///
/// Nested `details` are merged in, then `code` (or `errorCode` when details already carry a
/// `code`), `message`, `retryable` and `retryAfterMs`.
func gatewayErrorDetails(_ error: ErrorShape?) -> [String: OpenClawProtocol.AnyCodable] {
    var details: [String: OpenClawProtocol.AnyCodable] = [:]
    if let nested = error?.details?.dictionaryValue {
        details.merge(nested) { _, nestedValue in nestedValue }
    }
    if let error {
        if details["code"] == nil {
            details["code"] = OpenClawProtocol.AnyCodable(error.code)
        } else {
            details["errorCode"] = OpenClawProtocol.AnyCodable(error.code)
        }
        details["message"] = OpenClawProtocol.AnyCodable(error.message)
        if let retryable = error.retryable {
            details["retryable"] = OpenClawProtocol.AnyCodable(retryable)
        }
        if let retryAfterMs = error.retryafterms {
            details["retryAfterMs"] = OpenClawProtocol.AnyCodable(retryAfterMs)
        }
    }
    return details
}

/// Bridges task cancellation into the request continuation without racing send.
final class GatewayRequestCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    func cancel() {
        self.lock.lock()
        self.cancelled = true
        self.lock.unlock()
    }
}

extension GatewayChannelActor {
    struct PendingRequest {
        let continuation: CheckedContinuation<GatewayFrame, Error>
        var timeoutTask: Task<Void, Never>?
        let transportLifetime = WebSocketRequestLifetime()
    }

    enum ConnectChallengeError: Error {
        case invalid
    }

    /// Default operator scopes requested when the caller supplies no connect options.
    public static let defaultOperatorConnectScopes: [String] = [
        "operator.admin",
        "operator.read",
        "operator.write",
        "operator.approvals",
        "operator.questions",
        "operator.pairing",
    ]

    struct SelectedConnectAuth {
        let authToken: String?
        let authBootstrapToken: String?
        let authDeviceToken: String?
        let authPassword: String?
        let signatureToken: String?
        let storedToken: String?
        let storedScopes: [String]?
        let authSource: GatewayAuthSource
        let suppressedDeviceTokenRetry: Bool
    }
}

extension GatewayChannelActor.SelectedConnectAuth {
    /// Credential native HTTP adapters may reuse for this socket's gateway resources.
    ///
    /// A hello-issued device token for the same role wins; otherwise the credential accepted by
    /// this socket. Bootstrap enrollment credentials never authorize resource downloads.
    func httpResourceBearer(hello: HelloOk, role: String) -> String? {
        if (hello.auth["role"]?.stringValue ?? role) == role,
           let token = hello.auth["deviceToken"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            return token
        }
        return switch self.authSource {
        case .deviceToken: self.authDeviceToken ?? self.authToken
        case .sharedToken: self.authToken
        case .password: self.authPassword
        case .bootstrapToken, .none: nil
        }
    }

    /// HMAC-SHA256 fingerprint over length-framed credential values, computed only with a key.
    func makeAuthBinding(key: SymmetricKey?, deviceId: String?) -> GatewayAuthBinding {
        let credentialFingerprint = key.map { key in
            var values = [
                self.authSource.rawValue,
                deviceId ?? "",
            ]
            if let authToken = self.authToken {
                values.append(contentsOf: ["token", authToken])
                if let authDeviceToken = self.authDeviceToken {
                    values.append(contentsOf: ["deviceToken", authDeviceToken])
                }
            } else if let authBootstrapToken = self.authBootstrapToken {
                values.append(contentsOf: ["bootstrapToken", authBootstrapToken])
            } else if let authPassword = self.authPassword {
                values.append(contentsOf: ["password", authPassword])
            }
            let framed = values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            let tag = HMAC<SHA256>.authenticationCode(for: Data(framed.utf8), using: key)
            return tag.map { String(format: "%02x", $0) }.joined()
        }
        return GatewayAuthBinding(
            source: self.authSource,
            credentialFingerprint: credentialFingerprint)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}

extension Optional where Wrapped == String {
    /// Trimmed value, or `nil` when absent or blank.
    var gatewayTrimmedNonEmpty: String? {
        self?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
