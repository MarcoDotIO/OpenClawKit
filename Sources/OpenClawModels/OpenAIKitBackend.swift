import Foundation
import OpenClawCore
#if canImport(OpenAIKit)
import OpenAIKit
#endif

#if !canImport(OpenAIKit)
struct OpenAIRequestOptions: Sendable, Equatable {
    let timeoutInterval: TimeInterval
    let maxRetries: Int
    let additionalHeaders: [String: String]

    init(
        timeoutInterval: TimeInterval,
        maxRetries: Int,
        additionalHeaders: [String: String]
    ) {
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.additionalHeaders = additionalHeaders
    }
}
#endif

#if canImport(OpenAIKit)
protocol OpenAIKitChatRequesting {
    func generateChatCompletion(parameters: ChatParameters) async throws -> ChatResponse
}

extension OpenAI: OpenAIKitChatRequesting {}

protocol OpenAIKitResponsesRequesting {
    func createResponse(parameters: ResponseCreateParameters) async throws -> ResponseObject
}

extension OpenAI: OpenAIKitResponsesRequesting {
    func createResponse(parameters: ResponseCreateParameters) async throws -> ResponseObject {
        try await self.responses.create(parameters: parameters)
    }
}
#else
protocol OpenAIKitChatRequesting: Sendable {}
protocol OpenAIKitResponsesRequesting: Sendable {}
#endif
typealias OpenAIKitChatClientFactory = @Sendable (
    _ providerID: String,
    _ resolved: OpenAIKitResolvedRequest
) throws -> any OpenAIKitChatRequesting

typealias OpenAIKitResponsesClientFactory = @Sendable (
    _ providerID: String,
    _ resolved: OpenAIKitResolvedRequest
) throws -> any OpenAIKitResponsesRequesting
struct OpenAIKitResolvedRequest: Sendable {
    enum Authorization: Sendable, Equatable {
        case bearerToken(String)
        case none
    }

    private static let authorizationOverridePlaceholder = "openclawkit-header-override"

    let authorization: Authorization
    let baseURL: URL
    let modelID: String
    let organizationID: String?
    let projectID: String?
    let webhookSecret: String?
    let requestOptions: OpenAIRequestOptions

    #if canImport(OpenAIKit)
    var clientConfiguration: Configuration? {
        let apiKey: String?
        switch self.authorization {
        case .bearerToken(let token):
            apiKey = token
        case .none:
            if let override = self.requestOptions.additionalHeaders["Authorization"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty
            {
                apiKey = Self.authorizationOverridePlaceholder
            } else {
                apiKey = nil
            }
        }

        guard let apiKey else {
            return nil
        }

        return Configuration(
            apiKey: apiKey,
            organizationId: self.organizationID,
            projectId: self.projectID,
            webhookSecret: self.webhookSecret,
            baseURL: self.baseURL,
            requestOptions: self.requestOptions
        )
    }
    #else
    var clientConfiguration: Bool? {
        nil
    }
    #endif
}

enum OpenAIKitClientFactory {
    private static let defaultTimeoutInterval: TimeInterval = 30
    private static let defaultMaxRetries = 0

    static func resolve(
        providerID: String,
        configuration: OpenAIModelConfig,
        request: ModelGenerationRequest
    ) throws -> OpenAIKitResolvedRequest {
        let apiKey = try ProviderRequestResolution.resolveAPIKey(
            configured: configuration.apiKey,
            request: request,
            providerID: providerID
        )
        let baseURL = try ProviderRequestResolution.resolveBaseURL(
            configured: configuration.baseURL,
            request: request,
            providerID: providerID
        )
        let metadata = request.metadata
        return OpenAIKitResolvedRequest(
            authorization: .bearerToken(apiKey),
            baseURL: baseURL,
            modelID: ProviderRequestResolution.resolveModelID(
                request: request,
                configured: configuration.modelID,
                fallback: "gpt-4.1-mini"
            ),
            organizationID: self.metadataValue(in: metadata, keys: ["openai.organizationID", "openai.organizationId"]),
            projectID: self.metadataValue(in: metadata, keys: ["openai.projectID", "openai.projectId"]),
            webhookSecret: self.metadataValue(in: metadata, keys: ["openai.webhookSecret"]),
            requestOptions: self.requestOptions(
                configuredHeaders: request.resolvedRequestHeaders,
                metadata: metadata,
                request: request
            )
        )
    }

    static func resolve(
        providerID: String,
        configuration: ProviderServiceConfig,
        request: ModelGenerationRequest
    ) throws -> OpenAIKitResolvedRequest {
        let baseURL = try ProviderRequestResolution.resolveBaseURL(
            configured: configuration.baseURL,
            request: request,
            providerID: providerID
        )
        let authorization = try self.resolveAuthorization(
            providerID: providerID,
            configuration: configuration,
            request: request
        )
        let metadata = configuration.metadata.merging(request.metadata) { _, requestValue in requestValue }
        var headers = ProviderRequestResolution.mergedHeaders(configured: configuration.headers, request: request)
        if let organizationHeader = ModelGenerationRequest.normalized(configuration.organizationID) {
            headers["x-organization-id"] = organizationHeader
        }

        return OpenAIKitResolvedRequest(
            authorization: authorization,
            baseURL: baseURL,
            modelID: ProviderRequestResolution.resolveModelID(
                request: request,
                configured: configuration.modelID,
                fallback: "gpt-4.1-mini"
            ),
            organizationID: self.metadataValue(in: metadata, keys: ["openai.organizationID", "openai.organizationId"]),
            projectID: self.metadataValue(in: metadata, keys: ["openai.projectID", "openai.projectId"]),
            webhookSecret: self.metadataValue(in: metadata, keys: ["openai.webhookSecret"]),
            requestOptions: self.requestOptions(
                configuredHeaders: headers,
                metadata: metadata,
                request: request
            )
        )
    }

    #if canImport(OpenAIKit)
    @available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
    static func makeClient(
        providerID: String,
        resolved: OpenAIKitResolvedRequest
    ) throws -> OpenAI {
        guard let configuration = resolved.clientConfiguration else {
            throw OpenClawCoreError.invalidConfiguration(
                "\(providerID) requires bearer-style auth or an Authorization header override for OpenAIKit transport"
            )
        }
        return OpenAI(configuration)
    }

    @available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
    static func makeChatClient(
        providerID: String,
        resolved: OpenAIKitResolvedRequest
    ) throws -> any OpenAIKitChatRequesting {
        try self.makeClient(providerID: providerID, resolved: resolved)
    }

    @available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
    static func makeResponsesClient(
        providerID: String,
        resolved: OpenAIKitResolvedRequest
    ) throws -> any OpenAIKitResponsesRequesting {
        try self.makeClient(providerID: providerID, resolved: resolved)
    }
    #else
    static func makeChatClient(
        providerID: String,
        resolved: OpenAIKitResolvedRequest
    ) throws -> any OpenAIKitChatRequesting {
        _ = resolved
        throw OpenClawCoreError.unavailable("\(providerID) OpenAIKit transport is unavailable on this platform")
    }

    static func makeResponsesClient(
        providerID: String,
        resolved: OpenAIKitResolvedRequest
    ) throws -> any OpenAIKitResponsesRequesting {
        _ = resolved
        throw OpenClawCoreError.unavailable("\(providerID) OpenAIKit transport is unavailable on this platform")
    }
    #endif
    private static func resolveAuthorization(
        providerID: String,
        configuration: ProviderServiceConfig,
        request: ModelGenerationRequest
    ) throws -> OpenAIKitResolvedRequest.Authorization {
        switch configuration.authMode {
        case .apiKey:
            return .bearerToken(
                try ProviderRequestResolution.resolveAPIKey(
                    configured: configuration.apiKey,
                    request: request,
                    providerID: providerID
                )
            )
        case .bearerToken, .oauthToken:
            return .bearerToken(
                try ProviderRequestResolution.resolveAccessToken(
                    configured: configuration.accessToken,
                    request: request,
                    providerID: providerID
                )
            )
        case .none:
            return .none
        case .awsSDK:
            throw OpenClawCoreError.invalidConfiguration(
                "\(providerID) does not support aws-sdk auth mode for OpenAIKit-backed requests"
            )
        }
    }

    private static func requestOptions(
        configuredHeaders: [String: String],
        metadata: [String: String],
        request: ModelGenerationRequest
    ) -> OpenAIRequestOptions {
        OpenAIRequestOptions(
            timeoutInterval: self.timeoutInterval(metadata: metadata, request: request),
            maxRetries: self.maxRetries(metadata: metadata),
            additionalHeaders: self.normalizedHeaders(configuredHeaders)
        )
    }

    private static func timeoutInterval(
        metadata: [String: String],
        request: ModelGenerationRequest
    ) -> TimeInterval {
        if let timeoutMs = request.policy.requestTimeoutMs {
            return TimeInterval(timeoutMs) / 1000
        }
        if let configuredMs = self.integerMetadataValue(in: metadata, keys: ["openai.requestTimeoutMs"]) {
            return TimeInterval(configuredMs) / 1000
        }
        return self.defaultTimeoutInterval
    }

    private static func maxRetries(metadata: [String: String]) -> Int {
        self.integerMetadataValue(in: metadata, keys: ["openai.maxRetries"]) ?? self.defaultMaxRetries
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { partial, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                return
            }
            partial[key] = value
        }
    }

    private static func metadataValue(
        in metadata: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = ModelGenerationRequest.normalized(metadata[key]) {
                return value
            }
        }
        return nil
    }

    private static func integerMetadataValue(
        in metadata: [String: String],
        keys: [String]
    ) -> Int? {
        for key in keys {
            guard let rawValue = self.metadataValue(in: metadata, keys: [key]),
                  let parsed = Int(rawValue)
            else {
                continue
            }
            return max(0, parsed)
        }
        return nil
    }
}

enum OpenAIKitErrorNormalizer {
    static func normalize(
        _ error: Error,
        providerID: String
    ) -> OpenClawCoreError {
        if let coreError = error as? OpenClawCoreError {
            return coreError
        }
        #if canImport(OpenAIKit)
        if let apiError = error as? OpenAIAPIError {
            return .unavailable(self.message(for: apiError, providerID: providerID))
        }
        if let response = error as? OpenAIErrorResponse {
            return .unavailable("\(providerID) request failed: \(response.error.message)")
        }
        if let responseMessage = error as? OpenAIErrorMessage {
            return .unavailable("\(providerID) request failed: \(responseMessage.message)")
        }
        if let openAIError = error as? OpenAIError {
            return self.normalize(openAIError, providerID: providerID)
        }
        #endif
        if let urlError = error as? URLError {
            return .unavailable("\(providerID) transport failed: \(urlError.localizedDescription)")
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return .unavailable(
            "\(providerID) request failed\(message.isEmpty ? "" : ": \(message)")"
        )
    }

    #if canImport(OpenAIKit)
    private static func normalize(
        _ error: OpenAIError,
        providerID: String
    ) -> OpenClawCoreError {
        switch error {
        case .noApiKey:
            return .invalidConfiguration("\(providerID) API key is required")
        case .noBody:
            return .invalidConfiguration("\(providerID) request body is required")
        case .invalidUrl:
            return .invalidConfiguration("\(providerID) base URL is invalid")
        case .invalidData:
            return .unavailable("\(providerID) response payload was invalid")
        case .notImplemented:
            return .unavailable("\(providerID) requested operation is not implemented by OpenAIKit")
        case .incompatibleImageParameter:
            return .invalidConfiguration("\(providerID) request payload is incompatible with OpenAIKit")
        case .promptThreshold:
            return .unavailable("\(providerID) request exceeded OpenAI prompt threshold")
        case .unknownError:
            return .unavailable("\(providerID) request failed with an unknown OpenAIKit error")
        }
    }

    private static func message(
        for error: OpenAIAPIError,
        providerID: String
    ) -> String {
        switch error {
        case .badRequest(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 400,
                fallback: "bad request",
                payload: payload
            )
        case .authentication(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 401,
                fallback: "authentication failed",
                payload: payload
            )
        case .permissionDenied(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 403,
                fallback: "permission denied",
                payload: payload
            )
        case .notFound(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 404,
                fallback: "resource not found",
                payload: payload
            )
        case .conflict(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 409,
                fallback: "request conflict",
                payload: payload
            )
        case .unprocessableEntity(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 422,
                fallback: "request was unprocessable",
                payload: payload
            )
        case .rateLimit(let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: 429,
                fallback: "rate limit exceeded",
                payload: payload
            )
        case .internalServer(let statusCode, let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: statusCode,
                fallback: "server error",
                payload: payload
            )
        case .unexpectedStatusCode(let statusCode, let payload):
            return self.apiMessage(
                providerID: providerID,
                statusCode: statusCode,
                fallback: "unexpected status code",
                payload: payload
            )
        }
    }

    private static func apiMessage(
        providerID: String,
        statusCode: Int,
        fallback: String,
        payload: OpenAIErrorResponse?
    ) -> String {
        let detail = payload?.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty {
            return "\(providerID) request failed with status \(statusCode): \(detail)"
        }
        return "\(providerID) request failed with status \(statusCode): \(fallback)"
    }
    #endif
}
