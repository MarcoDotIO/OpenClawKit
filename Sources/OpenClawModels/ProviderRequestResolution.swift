import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenClawCore

extension ModelGenerationRequest {
    var resolvedBaseURL: String? {
        Self.normalized(self.metadata["provider.baseURL"])
            ?? Self.normalized(self.metadata["baseURL"])
    }

    var resolvedModelID: String? {
        Self.normalized(self.modelID) ?? Self.normalized(self.metadata["model"])
    }

    /// Opaque per-session identifier for `prompt_cache_key` and the session-affinity headers
    /// (`session_id`, `x-client-request-id`, `x-session-affinity`).
    ///
    /// Routing session keys embed channel peer ids (`agent:main:whatsapp:direct:+15551234567`), so
    /// they never go on the wire: an explicit `metadata["promptCacheKey"]` (clamped to 64 characters,
    /// upstream `clampOpenAIPromptCacheKey`) wins, otherwise the SHA-256 hex digest of the session key
    /// (64 characters) keeps the key stable per session without revealing it.
    var promptCacheKey: String {
        if let explicit = Self.normalized(self.metadata["promptCacheKey"]) {
            return String(explicit.prefix(64))
        }
        return OpenClawCrypto.sha256Hex(Data(self.sessionKey.utf8))
    }

    var resolvedAPIKey: String? {
        Self.normalized(self.metadata["auth.apiKey"]) ?? Self.normalized(self.metadata["apiKey"])
    }

    var resolvedAccessToken: String? {
        Self.normalized(self.metadata["auth.accessToken"])
            ?? Self.normalized(self.metadata["auth.token"])
            ?? Self.normalized(self.metadata["accessToken"])
    }

    var resolvedRequestHeaders: [String: String] {
        self.headers.reduce(into: [String: String]()) { partial, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            partial[key] = value
        }
    }

    static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum ProviderRequestResolution {
    static func resolveBaseURL(
        configured: String,
        request: ModelGenerationRequest,
        providerID: String
    ) throws -> URL {
        let raw = request.resolvedBaseURL ?? ModelGenerationRequest.normalized(configured)
        guard let raw, let url = URL(string: raw) else {
            throw OpenClawCoreError.invalidConfiguration("\(providerID) base URL is invalid")
        }
        return url
    }

    static func resolveModelID(
        request: ModelGenerationRequest,
        configured: String,
        fallback: String
    ) -> String {
        request.resolvedModelID ?? ModelGenerationRequest.normalized(configured) ?? fallback
    }

    static func resolveAPIKey(
        configured: String?,
        request: ModelGenerationRequest,
        providerID: String
    ) throws -> String {
        if let key = ModelGenerationRequest.normalized(configured) ?? request.resolvedAPIKey {
            return key
        }
        throw OpenClawCoreError.invalidConfiguration("\(providerID) API key is required")
    }

    static func resolveAccessToken(
        configured: String?,
        request: ModelGenerationRequest,
        providerID: String
    ) throws -> String {
        if let token = ModelGenerationRequest.normalized(configured) ?? request.resolvedAccessToken {
            return token
        }
        throw OpenClawCoreError.invalidConfiguration("\(providerID) access token is required")
    }

    static func applyHeaders(
        _ headers: [String: String],
        request: inout URLRequest
    ) {
        for (key, value) in headers {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            request.setValue(normalizedValue, forHTTPHeaderField: normalizedKey)
        }
    }

    /// First non-empty metadata value for `keys`, request metadata before configured metadata.
    static func metadataValue(
        _ requestMetadata: [String: String],
        _ configuredMetadata: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = ModelGenerationRequest.normalized(requestMetadata[key]) {
                return value
            }
        }
        for key in keys {
            if let value = ModelGenerationRequest.normalized(configuredMetadata[key]) {
                return value
            }
        }
        return nil
    }

    static func mergedHeaders(
        configured: [String: String],
        request: ModelGenerationRequest
    ) -> [String: String] {
        configured.merging(request.resolvedRequestHeaders) { _, requestValue in requestValue }
    }
}
