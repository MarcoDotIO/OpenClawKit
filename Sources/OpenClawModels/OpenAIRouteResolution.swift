import Foundation
import OpenClawCore
import OpenClawProtocol

/// OpenAI route classification and legacy `openai-codex` resolution (upstream
/// `extensions/openai/base-url.ts`, `model-route-contract.ts`, `src/config/legacy-codex-provider.ts`).
///
/// `openai-codex` merged into `openai`: the ChatGPT (OAuth) route is provider `openai` with API
/// `openai-chatgpt-responses` at `https://chatgpt.com/backend-api/codex`. Legacy `openai-codex/<m>`
/// and `codex/<m>` refs still resolve, as `openai/<m>` on that route.
public enum OpenAIRouteResolution {
    /// OpenAI Platform base URL.
    public static let platformBaseURL = "https://api.openai.com/v1"
    /// Canonical ChatGPT/Codex Responses base URL.
    public static let chatGPTBaseURL = "https://chatgpt.com/backend-api/codex"
    /// Legacy provider ids that resolve to the ChatGPT route of `openai`.
    public static let legacyCodexProviderIDs: Set<String> = ["openai-codex", "codex"]

    /// Endpoint kind of an OpenAI base URL.
    public enum EndpointKind: String, Sendable, Equatable {
        /// No base URL configured.
        case unresolved
        /// `https://api.openai.com` (`/` or `/v1`).
        case platform
        /// An accepted `https://chatgpt.com/backend-api…` path.
        case chatGPT = "chatgpt"
        /// Any other valid http(s) URL.
        case custom
        /// Unparseable URL, credentials in the URL, or an official host with an unsafe form.
        case invalid
    }

    private static let platformPaths: Set<String> = ["", "/", "/v1", "/v1/"]
    private static let chatGPTPaths: Set<String> = [
        "/backend-api", "/backend-api/", "/backend-api/v1", "/backend-api/v1/",
        "/backend-api/codex", "/backend-api/codex/", "/backend-api/codex/v1", "/backend-api/codex/v1/",
        "/backend-api/codex/responses", "/backend-api/codex/responses/",
    ]

    /// Classifies a base URL. Official hosts must be https without port, query or fragment.
    /// - Parameter baseURL: Base URL string.
    public static func classify(baseURL: String?) -> EndpointKind {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return .unresolved
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else {
            return .invalid
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard host == "api.openai.com" || host == "chatgpt.com" else {
            return .custom
        }
        if scheme != "https" || components.port != nil || components.query != nil || components.fragment != nil {
            return .invalid
        }
        if host == "api.openai.com", self.platformPaths.contains(components.path) {
            return .platform
        }
        if host == "chatgpt.com", self.chatGPTPaths.contains(components.path) {
            return .chatGPT
        }
        return .invalid
    }

    /// Canonicalizes accepted ChatGPT paths to ``chatGPTBaseURL``; other URLs are returned unchanged.
    /// - Parameter baseURL: Base URL string.
    public static func canonicalizeChatGPTBaseURL(_ baseURL: String) -> String {
        self.classify(baseURL: baseURL) == .chatGPT ? self.chatGPTBaseURL : baseURL
    }

    /// Whether a provider id is a legacy `openai-codex` alias.
    /// - Parameter providerID: Provider identifier.
    public static func isLegacyCodexProviderID(_ providerID: String) -> Bool {
        self.legacyCodexProviderIDs.contains(providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Normalizes an OpenAI model id: the shipped legacy alias `gpt-5.4-codex` becomes `gpt-5.4`;
    /// other ids keep their authored case.
    /// - Parameter modelID: Model identifier.
    public static func normalizeModelID(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "gpt-5.4-codex" || lowered == "openai/gpt-5.4-codex" {
            return "gpt-5.4"
        }
        return trimmed
    }

    /// Resolved legacy model ref.
    public struct LegacyRef: Sendable, Equatable {
        /// Canonical provider id (`openai`).
        public var providerID: String
        /// Model id.
        public var modelID: String
        /// Transport API (`openai-chatgpt-responses`).
        public var api: ModelAPI
        /// Auth mode (`oauth`).
        public var auth: ModelProviderAuthMode
        /// Base URL (ChatGPT route).
        public var baseURL: String

        /// Canonical `provider/model` ref.
        public var ref: String {
            "\(self.providerID)/\(self.modelID)"
        }
    }

    /// Resolves a legacy `openai-codex/<m>` or `codex/<m>` ref to `openai/<m>` on the ChatGPT route.
    /// - Parameter ref: Model ref.
    /// - Returns: The resolved ref, or `nil` when the ref is not a legacy codex ref.
    public static func resolveLegacyCodexRef(_ ref: String) -> LegacyRef? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash])
        guard self.isLegacyCodexProviderID(provider) else { return nil }
        let model = self.normalizeModelID(String(trimmed[trimmed.index(after: slash)...]))
        guard !model.isEmpty else { return nil }
        return LegacyRef(
            providerID: "openai",
            modelID: model,
            api: .openAIChatGPTResponses,
            auth: .oauth,
            baseURL: self.chatGPTBaseURL
        )
    }

    /// Rewrites a legacy `openai-codex` provider config onto the `openai` ChatGPT route.
    /// - Parameter config: Legacy provider config.
    /// - Returns: The config with ChatGPT api, OAuth auth and canonical base URL.
    public static func migrateLegacyCodexConfig(_ config: ModelProviderConfig) -> ModelProviderConfig {
        var migrated = config
        migrated.api = .openAIChatGPTResponses
        if migrated.auth == nil || migrated.auth == .apiKey {
            migrated.auth = .oauth
        }
        let base = migrated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || self.classify(baseURL: base) == .chatGPT || self.classify(baseURL: base) == .platform {
            migrated.baseURL = self.chatGPTBaseURL
        }
        migrated.models = migrated.models.map { model in
            var model = model
            model.id = self.normalizeModelID(model.id)
            if model.api == nil || model.api == .openAIResponses || model.api == .openAIChatGPTResponses {
                model.api = .openAIChatGPTResponses
            }
            return model
        }
        return migrated
    }

    /// Resolves the ChatGPT `…/codex/responses` endpoint for a base URL.
    /// - Parameter baseURL: Base URL string (empty uses ``chatGPTBaseURL``).
    public static func chatGPTResponsesURL(baseURL: String) -> String {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.chatGPTBaseURL : baseURL
        let normalized = ProviderEndpointSettings.trimmingTrailingSlashes(raw)
        if normalized.hasSuffix("/codex/responses") {
            return normalized
        }
        if normalized.hasSuffix("/codex") {
            return normalized + "/responses"
        }
        if normalized.hasSuffix("/codex/v1") {
            return String(normalized.dropLast("/v1".count)) + "/responses"
        }
        if normalized.hasSuffix("/backend-api/v1") {
            return String(normalized.dropLast("/v1".count)) + "/codex/responses"
        }
        return normalized + "/codex/responses"
    }

    /// Reads the ChatGPT account id from an OAuth access token (JWT claim
    /// `https://api.openai.com/auth.chatgpt_account_id`).
    /// - Parameter token: Access token.
    public static func chatGPTAccountID(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload += "="
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let claim = object["https://api.openai.com/auth"]?.dictionaryValue,
              let accountID = claim["chatgpt_account_id"]?.stringValue,
              !accountID.isEmpty
        else {
            return nil
        }
        return accountID
    }
}

/// Azure OpenAI and Google Vertex endpoint helpers.
enum ProviderEndpointTemplates {
    /// Default Azure OpenAI Responses `api-version` (v1 GA surface).
    static let azureDefaultAPIVersion = "preview"

    /// Substitutes `{location}` / `{region}` in a Vertex base URL template.
    static func vertexBaseURL(_ template: String, location: String?) -> String {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = trimmed.isEmpty ? "us-central1" : trimmed
        return template
            .replacingOccurrences(of: "{location}", with: region)
            .replacingOccurrences(of: "{region}", with: region)
    }
}
