import Foundation
import OpenClawCore

// Maps FoundationModels framework errors onto ``FoundationModelsError`` codes.
//
// OS 27 throws `LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error`,
// `GeneratedContent.ParsingError` and `PrivateCloudComputeLanguageModel.Error`; OS 26 throws the
// (27-deprecated) `LanguageModelSession.GenerationError`. String sniffing for sandbox/model-catalog
// failures stays only as a last-resort fallback for untyped errors. SystemLanguageModel-specific
// cases are compiled out on watchOS, where the on-device model does not exist.

/// Converts framework errors into ``FoundationModelsError`` values.
public enum FoundationModelsErrorMapper {
    /// Maps an error thrown by FoundationModels.
    ///
    /// `CancellationError`, ``FoundationModelsError`` and ``OpenClawCoreError`` pass through unchanged;
    /// unrecognized errors are returned as-is unless they look like a sandbox/model-catalog failure.
    /// - Parameter error: Error thrown by a Foundation Models call.
    /// - Returns: The mapped error.
    public static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is FoundationModelsError || error is OpenClawCoreError {
            return error
        }
        #if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
        if let mapped = Self.mapFramework(error) {
            return mapped
        }
        #endif
        #if canImport(Darwin)
        if Self.containsModelManagerEntitlementError(error as NSError) {
            return Self.notEntitled
        }
        #endif
        let description = String(describing: error)
        if description.localizedCaseInsensitiveContains("modelcatalog")
            || description.localizedCaseInsensitiveContains("sandbox restriction")
        {
            return FoundationModelsError(
                code: .unavailable,
                message: FoundationModelsRuntimeAvailability.unavailable(.restrictedEnvironment).message
            )
        }
        return error
    }

    /// Raised when the model service rejects the calling process (for example Private Cloud Compute
    /// without Apple's managed entitlement, surfaced as `ModelManagerError` 1046).
    static let notEntitled = FoundationModelsError(
        code: .unavailable,
        message: "Apple Foundation Models rejected the request because this app is not entitled to use the model "
            + "(ModelManagerError 1046). Private Cloud Compute requires Apple's managed entitlement; "
            + "see https://developer.apple.com/private-cloud-compute/.",
        retryable: false
    )

    /// Whether an error chain contains `ModelManagerServices.ModelManagerError` 1046 (not entitled).
    static func containsModelManagerEntitlementError(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain.hasSuffix("ModelManagerError"), error.code == 1_046 {
            return true
        }
        guard depth < 8 else { return false }
        var underlying: [NSError] = []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            underlying.append(single)
        }
        if let multiple = error.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] {
            underlying.append(contentsOf: multiple)
        }
        return underlying.contains { Self.containsModelManagerEntitlementError($0, depth: depth + 1) }
    }
}

#if canImport(FoundationModels) && !os(tvOS) && (!os(watchOS) || compiler(>=6.4))
import FoundationModels

extension FoundationModelsErrorMapper {
    static func mapFramework(_ error: any Error) -> FoundationModelsError? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            if let mapped = Self.map27(error) {
                return mapped
            }
        }
        #endif
        #if !os(watchOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let mapped = Self.map26(error) {
                return mapped
            }
            if let toolError = error as? LanguageModelSession.ToolCallError {
                return Self.toolFailure(toolName: toolError.tool.name, underlying: toolError.underlyingError)
            }
        }
        #endif
        #if !os(watchOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *), let schemaError = error as? GenerationSchema.SchemaError {
            return FoundationModelsError.invalidSchema(schemaError.localizedDescription)
        }
        #else
        if #available(watchOS 27.0, *), let schemaError = error as? GenerationSchema.SchemaError {
            return FoundationModelsError.invalidSchema(schemaError.localizedDescription)
        }
        #endif
        return nil
    }

    private static func toolFailure(toolName: String, underlying: any Error) -> FoundationModelsError {
        let mapped = Self.map(underlying)
        let detail = (mapped as? LocalizedError)?.errorDescription ?? String(describing: mapped)
        return FoundationModelsError(code: .toolFailed, message: "Tool '\(toolName)' failed: \(detail)")
    }

    #if !os(watchOS)
    /// OS 26 errors (`LanguageModelSession.GenerationError`, deprecated in 27).
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func map26(_ error: any Error) -> FoundationModelsError? {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return nil
        }
        switch generationError {
        case .exceededContextWindowSize:
            return FoundationModelsError(
                code: .contextOverflow,
                message: "Apple Foundation Models context window exceeded."
            )
        case .assetsUnavailable:
            return FoundationModelsError(
                code: .unavailable,
                message: FoundationModelsRuntimeAvailability.unavailable(.assetsUnavailable).message
            )
        case .guardrailViolation:
            return Self.guardrail
        case .refusal:
            return Self.refusal
        case .unsupportedGuide:
            return FoundationModelsError(code: .unsupported, message: "Apple Foundation Models does not support a generation guide in this schema.")
        case .unsupportedLanguageOrLocale:
            return FoundationModelsError(code: .unsupported, message: "Apple Foundation Models does not support the request language or locale.")
        case .decodingFailure:
            return FoundationModelsError.malformedJSON
        case .rateLimited:
            return FoundationModelsError(code: .rateLimited, message: "Apple Foundation Models is rate limited; retry later.")
        case .concurrentRequests:
            return Self.busy
        @unknown default:
            return FoundationModelsError(code: .unknown, message: generationError.localizedDescription)
        }
    }
    #endif

    #if compiler(>=6.4)
    /// OS 27 errors.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    static func map27(_ error: any Error) -> FoundationModelsError? {
        if let modelError = error as? LanguageModelError {
            return Self.map(modelError)
        }
        if let sessionError = error as? LanguageModelSession.Error {
            switch sessionError {
            case .concurrentRequests, .transcriptMutationWhileResponding:
                return Self.busy
            @unknown default:
                return Self.busy
            }
        }
        #if !os(watchOS)
        if let systemError = error as? SystemLanguageModel.Error {
            switch systemError {
            case .assetsUnavailable:
                return FoundationModelsError(
                    code: .unavailable,
                    message: FoundationModelsRuntimeAvailability.unavailable(.assetsUnavailable).message
                )
            @unknown default:
                return FoundationModelsError(code: .unavailable, message: systemError.localizedDescription)
            }
        }
        #endif
        if error is GeneratedContent.ParsingError {
            // Never echo `rawContent`: it is model output.
            return FoundationModelsError.malformedJSON
        }
        if let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloudError {
            case .quotaLimitReached(let quota):
                return FoundationModelsError(
                    code: .rateLimited,
                    message: "Private Cloud Compute quota limit reached; retry after the quota resets.",
                    retryable: true,
                    resetDate: quota.resetDate
                )
            case .networkFailure:
                return FoundationModelsError(code: .networkFailure, message: "Private Cloud Compute could not reach the network.")
            case .serviceUnavailable:
                return FoundationModelsError(code: .serviceUnavailable, message: "Private Cloud Compute is temporarily unavailable.")
            @unknown default:
                return FoundationModelsError(code: .serviceUnavailable, message: cloudError.localizedDescription)
            }
        }
        return nil
    }

    /// Maps one `LanguageModelError` (OS 27).
    /// - Parameter error: Framework error.
    /// - Returns: The mapped error.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    public static func map(_ error: LanguageModelError) -> FoundationModelsError {
        switch error {
        case .contextSizeExceeded(let context):
            return FoundationModelsError(
                code: .contextOverflow,
                message: "Apple Foundation Models context window exceeded (\(context.tokenCount) of \(context.contextSize) tokens).",
                contextSize: context.contextSize,
                tokenCount: context.tokenCount
            )
        case .rateLimited(let limit):
            return FoundationModelsError(
                code: .rateLimited,
                message: "Apple Foundation Models is rate limited; retry later.",
                resetDate: limit.resetDate
            )
        case .guardrailViolation:
            return Self.guardrail
        case .refusal:
            return Self.refusal
        case .unsupportedCapability(let unsupported):
            let name = Self.capabilityName(unsupported.capability)
            return FoundationModelsError(
                code: .unsupportedCapability,
                message: "The selected Apple Foundation Models model does not support \(name).",
                capability: name
            )
        case .unsupportedTranscriptContent:
            return FoundationModelsError(code: .unsupported, message: "Apple Foundation Models does not support some transcript content.")
        case .unsupportedGenerationGuide:
            return FoundationModelsError(code: .unsupported, message: "Apple Foundation Models does not support a generation guide in this schema.")
        case .unsupportedLanguageOrLocale(let locale):
            return FoundationModelsError(
                code: .unsupported,
                message: "Apple Foundation Models does not support the language '\(locale.languageCode.identifier)'."
            )
        case .timeout:
            return FoundationModelsError(code: .timeout, message: "Apple Foundation Models timed out.")
        @unknown default:
            return FoundationModelsError(code: .unknown, message: error.localizedDescription)
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    static func capabilityName(_ capability: LanguageModelCapabilities.Capability) -> String {
        switch capability {
        case .vision:
            return "vision"
        case .reasoning:
            return "reasoning"
        case .toolCalling:
            return "toolCalling"
        case .guidedGeneration:
            return "guidedGeneration"
        default:
            return "unknown"
        }
    }
    #endif

    private static let guardrail = FoundationModelsError(
        code: .guardrail,
        message: "Apple Foundation Models declined the request because it triggered a safety guardrail."
    )

    private static let refusal = FoundationModelsError(
        code: .refusal,
        message: "Apple Foundation Models refused to answer this request."
    )

    private static let busy = FoundationModelsError(
        code: .busy,
        message: "The Apple Foundation Models session is already responding; retry after it finishes."
    )
}
#endif
