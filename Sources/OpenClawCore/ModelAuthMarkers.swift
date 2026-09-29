import Foundation

/// Non-secret model-auth marker values (port of upstream `src/agents/model-auth-markers.ts`).
///
/// Some providers persist a placeholder in `apiKey` instead of a credential: local runtimes
/// (`ollama-local`, `apple-fm-local`), ambient credential chains (`AWS_PROFILE`), OAuth-backed
/// markers (`oauth:<provider>`) and SecretRef header placeholders. Security audits and credential
/// checks must never report these as plaintext secrets.
///
/// Core cannot depend on OpenClawModels, so the Apple Foundation Models marker is defined here and
/// mirrors `FoundationModelsProvider.isNonSecretAuthMarker(_:)`.
public enum ModelAuthMarkers {
    /// Apple Foundation Models local marker (upstream `APPLE_FM_LOCAL_AUTH_MARKER`, bundled `apple-fm` plugin).
    public static let appleFoundationModelsLocal = "apple-fm-local"
    /// Bundled local-provider marker (upstream `CUSTOM_LOCAL_AUTH_MARKER`).
    public static let customLocal = "custom-local"
    /// Local Ollama marker.
    public static let ollamaLocal = "ollama-local"
    /// Codex app-server marker.
    public static let codexAppServer = "codex-app-server"
    /// Google Vertex credentials resolved outside API-key env vars.
    public static let gcpVertexCredentials = "gcp-vertex-credentials"
    /// Header placeholder for a non-env SecretRef (upstream `NON_ENV_SECRETREF_MARKER`).
    public static let nonEnvSecretRef = "secretref-managed"
    /// Prefix of persisted OAuth-backed API-key markers (`oauth:<provider>`).
    public static let oauthPrefix = "oauth:"
    /// Prefix of env-backed SecretRef header markers (`secretref-env:<NAME>`).
    public static let secretRefEnvHeaderPrefix = "secretref-env:"

    /// Markers from core and the bundled plugin manifests (`nonSecretAuthMarkers`).
    public static let knownMarkers: Set<String> = [
        customLocal, codexAppServer, gcpVertexCredentials, ollamaLocal, nonEnvSecretRef,
        appleFoundationModelsLocal, "llama-cpp-local", "lmstudio-local", "minimax-oauth",
        "openclaw:claude-cli-native-auth",
    ]

    /// Env-var names persisted as AWS SDK ambient-auth markers.
    public static let awsSDKEnvMarkers: Set<String> = ["AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID", "AWS_PROFILE"]

    /// Legacy env-var name markers kept for older `models.json` files.
    public static let legacyEnvAPIKeyMarkers: Set<String> = [
        "GOOGLE_API_KEY", "DEEPSEEK_API_KEY", "PERPLEXITY_API_KEY", "FIREWORKS_API_KEY", "NOVITA_API_KEY",
        "AZURE_OPENAI_API_KEY", "AZURE_API_KEY", "MINIMAX_CODE_PLAN_KEY",
    ]

    /// Whether `value` is a persisted non-secret placeholder rather than a real key
    /// (upstream `isNonSecretApiKeyMarker`).
    /// - Parameters:
    ///   - value: Configured `apiKey` (or header) value.
    ///   - includeEnvVarNames: Also treat the known env-var name markers as non-secret (default `true`).
    /// - Returns: `true` for known markers; `false` for empty values and anything else.
    public static func isNonSecretMarker(_ value: String?, includeEnvVarNames: Bool = true) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        if trimmed.hasPrefix(Self.oauthPrefix) || Self.knownMarkers.contains(trimmed) || Self.awsSDKEnvMarkers.contains(trimmed) {
            return true
        }
        if trimmed == Self.nonEnvSecretRef || trimmed.hasPrefix(Self.secretRefEnvHeaderPrefix) {
            return true
        }
        return includeEnvVarNames && Self.legacyEnvAPIKeyMarkers.contains(trimmed)
    }
}
