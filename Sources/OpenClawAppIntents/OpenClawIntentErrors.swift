import Foundation
import OpenClawKit
#if canImport(AppIntents)
import AppIntents
#endif

/// Errors thrown by OpenClaw intents and entity queries.
public enum OpenClawIntentError: Error, Sendable, Equatable, LocalizedError {
    /// ``OpenClawAppIntents/configure(host:)`` has not been called.
    case hostNotConfigured
    /// The prompt was empty.
    case emptyPrompt
    /// The run failed with a message.
    case runFailed(String)
    /// The run was aborted.
    case aborted
    /// The run did not finish in time.
    case timedOut
    /// The operation is not supported by the configured host.
    case unsupported(String)
    /// The gateway could not be reached or rejected the request.
    case gatewayUnavailable(String)

    /// User-facing description.
    public var errorDescription: String? {
        switch self {
        case .hostNotConfigured:
            return "OpenClaw is not ready yet. Open the app and try again."
        case .emptyPrompt:
            return "The prompt is empty."
        case let .runFailed(message):
            return message.isEmpty ? "The OpenClaw run failed." : message
        case .aborted:
            return "The OpenClaw run was stopped."
        case .timedOut:
            return "OpenClaw did not finish in time."
        case let .unsupported(message):
            return message
        case let .gatewayUnavailable(message):
            return message.isEmpty ? "The OpenClaw gateway is unavailable." : message
        }
    }

    /// Maps any error thrown while running an intent to a presentable error.
    ///
    /// Cancellation becomes ``aborted``; OpenClaw intent errors pass through; on OS 27 errors that
    /// conform to `CustomAppIntentErrorConvertible` (gateway, node and intent errors) are wrapped in
    /// `AppIntentError`; anything else becomes ``runFailed(_:)`` with its localized description.
    /// - Parameter error: Thrown error.
    /// - Returns: Error to rethrow from `perform()`.
    public static func presentable(_ error: any Error) -> any Error {
        if error is CancellationError {
            return OpenClawIntentError.aborted
        }
        #if compiler(>=6.4) && canImport(AppIntents)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            if let convertible = error as? any CustomAppIntentErrorConvertible {
                return AppIntentError(wrapping: convertible)
            }
        }
        #endif
        if let intentError = error as? OpenClawIntentError {
            return intentError
        }
        return OpenClawIntentError.runFailed(Self.message(for: error))
    }

    static func message(for error: any Error) -> String {
        if let auth = error as? GatewayConnectAuthError {
            return auth.message
        }
        if let response = error as? GatewayResponseError {
            return response.message
        }
        if let node = error as? OpenClawNodeError {
            return node.message
        }
        let description = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "The OpenClaw run failed." : description
    }
}

#if canImport(AppIntents)
extension OpenClawIntentError: CustomLocalizedStringResourceConvertible {
    /// Localized description shown by Siri and Shortcuts.
    public var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: self.errorDescription ?? "The OpenClaw run failed.")
    }
}
#endif

#if compiler(>=6.4) && canImport(AppIntents)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension OpenClawIntentError: CustomAppIntentErrorConvertible {
    /// App Intents representation.
    public var appIntentError: AppIntentError {
        let description = LocalizedStringResource(stringLiteral: self.errorDescription ?? "The OpenClaw run failed.")
        switch self {
        case .hostNotConfigured:
            return AppIntentError(predefinedError: AppIntentError.UserActionRequired.accountSetup, description: description)
        case .gatewayUnavailable:
            return AppIntentError(predefinedError: AppIntentError.Unrecoverable.networkFailure, description: description)
        case .unsupported:
            return AppIntentError(predefinedError: AppIntentError.Unrecoverable.unsupportedOnDevice, description: description)
        case .emptyPrompt, .runFailed, .aborted, .timedOut:
            return AppIntentError(description: description)
        }
    }
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension GatewayConnectAuthError: CustomAppIntentErrorConvertible {
    /// App Intents representation (pairing/auth failures ask the user to finish setup in the app).
    public var appIntentError: AppIntentError {
        let description = LocalizedStringResource(stringLiteral: self.message)
        if self.detail == .pairingRequired || self.isNonRecoverable {
            return AppIntentError(predefinedError: AppIntentError.UserActionRequired.accountSetup, description: description)
        }
        return AppIntentError(description: description)
    }
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension GatewayResponseError: CustomAppIntentErrorConvertible {
    /// App Intents representation of a gateway `{ ok: false }` response.
    public var appIntentError: AppIntentError {
        let description = LocalizedStringResource(stringLiteral: self.message)
        switch self.code {
        case "NOT_PAIRED", "UNAUTHORIZED", "FORBIDDEN":
            return AppIntentError(predefinedError: AppIntentError.UserActionRequired.accountSetup, description: description)
        case "UNAVAILABLE":
            return AppIntentError(predefinedError: AppIntentError.Unrecoverable.networkFailure, description: description)
        default:
            return AppIntentError(description: description)
        }
    }
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension OpenClawNodeError: CustomAppIntentErrorConvertible {
    /// App Intents representation of a node command error.
    public var appIntentError: AppIntentError {
        let description = LocalizedStringResource(stringLiteral: self.message)
        // `if` chains instead of an exhaustive switch keep this compiling when codes are added.
        if self.code == .notPaired || self.code == .unauthorized {
            return AppIntentError(predefinedError: AppIntentError.UserActionRequired.accountSetup, description: description)
        }
        if self.code == .unavailable || self.code == .backgroundUnavailable {
            return AppIntentError(predefinedError: AppIntentError.Unrecoverable.networkFailure, description: description)
        }
        return AppIntentError(description: description)
    }
}
#endif
