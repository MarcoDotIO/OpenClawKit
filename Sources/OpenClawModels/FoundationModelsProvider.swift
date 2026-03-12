import Foundation
import OpenClawCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runtime availability for Apple Foundation Models.
public enum FoundationModelsRuntimeAvailability: Sendable, Equatable {
    /// Foundation Models can be used for requests.
    case available
    /// Foundation Models are unavailable, with a concrete reason when known.
    case unavailable(Reason)

    /// Unavailability reasons surfaced by the framework or host platform.
    public enum Reason: Sendable, Equatable {
        case frameworkUnavailable
        case unsupportedOS
        case restrictedEnvironment
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
    }

    /// Convenience Boolean for simple gating.
    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    /// User-facing explanation for availability failures.
    public var message: String {
        switch self {
        case .available:
            return "Foundation Models are available."
        case .unavailable(.frameworkUnavailable):
            return "Foundation Models are unavailable on this platform."
        case .unavailable(.unsupportedOS):
            return "Foundation Models require Apple OS 26 or later."
        case .unavailable(.restrictedEnvironment):
            return "Foundation Models are unavailable in the current simulator or sandboxed runtime environment."
        case .unavailable(.deviceNotEligible):
            return "Foundation Models are not supported on this device."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence must be enabled to use Foundation Models."
        case .unavailable(.modelNotReady):
            return "Foundation Models are not ready yet. Try again in a moment."
        }
    }
}

/// Model provider backed by Apple Foundation Models APIs when available.
///
/// This is the preferred on-device Apple path for sample-app defaults when the
/// host device is eligible for Apple Intelligence and the Foundation Models
/// runtime reports availability. Requests stay on-device and use the system
/// Apple Silicon acceleration stack.
public struct FoundationModelsProvider: ModelProvider {
    /// Canonical provider identifier.
    public static let providerID = "foundation"
    /// Provider identifier.
    public let id: String

    /// Creates a Foundation Models provider.
    /// - Parameter id: Provider identifier.
    public init(id: String = FoundationModelsProvider.providerID) {
        self.id = id
    }

    /// Probes runtime availability for the system language model.
    /// - Returns: Structured availability state for the current environment.
    public static func runtimeAvailability() -> FoundationModelsRuntimeAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            #if targetEnvironment(simulator)
            return .unavailable(.restrictedEnvironment)
            #else
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled:
                    return .unavailable(.appleIntelligenceNotEnabled)
                case .modelNotReady:
                    return .unavailable(.modelNotReady)
                @unknown default:
                    return .unavailable(.modelNotReady)
                }
            }
            #endif
        }
        return .unavailable(.unsupportedOS)
        #else
        return .unavailable(.frameworkUnavailable)
        #endif
    }

    /// Generates a response using Foundation Models where supported.
    /// - Parameter request: Generation request payload.
    /// - Returns: Generation response payload.
    public func generate(_ request: ModelGenerationRequest) async throws -> ModelGenerationResponse {
        switch Self.runtimeAvailability() {
        case .available:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                let instructions = request.systemPrompt?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let session = LanguageModelSession(
                    model: .default,
                    tools: [],
                    instructions: instructions?.isEmpty == false ? instructions : nil
                )
                let response: LanguageModelSession.Response<String>
                do {
                    response = try await session.respond(to: request.prompt)
                } catch {
                    let description = String(describing: error)
                    if description.localizedCaseInsensitiveContains("modelcatalog") ||
                        description.localizedCaseInsensitiveContains("sandbox restriction")
                    {
                        throw OpenClawCoreError.unavailable(
                            FoundationModelsRuntimeAvailability.unavailable(.restrictedEnvironment).message
                        )
                    }
                    throw error
                }
                return ModelGenerationResponse(
                    text: response.content,
                    providerID: self.id,
                    modelID: "apple-foundation-default"
                )
            }
            #endif
            throw OpenClawCoreError.unavailable(
                FoundationModelsRuntimeAvailability.unavailable(.unsupportedOS).message
            )
        case .unavailable(let reason):
            _ = request
            throw OpenClawCoreError.unavailable(
                FoundationModelsRuntimeAvailability.unavailable(reason).message
            )
        }
    }
}
