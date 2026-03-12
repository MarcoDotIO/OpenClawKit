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

    static func mergedHeaders(
        configured: [String: String],
        request: ModelGenerationRequest
    ) -> [String: String] {
        configured.merging(request.resolvedRequestHeaders) { _, requestValue in requestValue }
    }
}
