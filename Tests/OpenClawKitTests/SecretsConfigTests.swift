import Foundation
import Testing
@testable import OpenClawCore

@Suite("Secrets config")
struct SecretsConfigTests {
    @Test
    func secretInputDecodesPlaintextAndEnvTemplateRefs() throws {
        let plaintext = try JSONDecoder().decode(SecretInput.self, from: Data(#""sk-live-123""#.utf8))
        let envRef = try JSONDecoder().decode(SecretInput.self, from: Data(#""${OPENAI_API_KEY}""#.utf8))

        #expect(plaintext == .string("sk-live-123"))
        #expect(envRef == .ref(SecretRef(source: .env, provider: DEFAULT_SECRET_PROVIDER_ALIAS, id: "OPENAI_API_KEY")))
    }

    @Test
    func secretRefDecodesLegacyProviderlessShapeAndValidatesIDs() throws {
        let payload = Data(#"{"source":"file","id":"/providers/openai/apiKey"}"#.utf8)
        let decoded = try JSONDecoder().decode(SecretRef.self, from: payload)

        #expect(decoded.provider == DEFAULT_SECRET_PROVIDER_ALIAS)
        #expect(decoded.validationError() == nil)
        #expect(SecretRef(source: .env, provider: "default", id: "openai_api_key").validationError() != nil)
        #expect(SecretRef(source: .exec, provider: "default", id: "../vault").validationError() != nil)
    }

    @Test
    func secretsConfigDecodesProvidersDefaultsAndResolutionSettings() throws {
        let json = #"""
        {
          "providers": {
            "default": {
              "source": "env",
              "allowlist": ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
            },
            "mounted-json": {
              "source": "file",
              "path": "/run/secrets/providers.json"
            },
            "vault": {
              "source": "exec",
              "command": "/usr/local/bin/openclaw-vault",
              "args": ["read"],
              "trustedDirs": ["/usr/local/bin"]
            }
          },
          "defaults": {
            "env": "default",
            "file": "mounted-json",
            "exec": "vault"
          },
          "resolution": {
            "maxProviderConcurrency": 6,
            "maxRefsPerProvider": 42,
            "maxBatchBytes": 2048
          }
        }
        """#

        let decoded = try JSONDecoder().decode(SecretsConfig.self, from: Data(json.utf8))

        guard case .env(let envProvider)? = decoded.providers["default"] else {
            Issue.record("Expected env secret provider")
            return
        }
        guard case .file(let fileProvider)? = decoded.providers["mounted-json"] else {
            Issue.record("Expected file secret provider")
            return
        }
        guard case .exec(let execProvider)? = decoded.providers["vault"] else {
            Issue.record("Expected exec secret provider")
            return
        }

        #expect(envProvider.allowlist == ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        #expect(fileProvider.mode == .json)
        #expect(fileProvider.timeoutMs == 5_000)
        #expect(execProvider.noOutputTimeoutMs == 5_000)
        #expect(execProvider.jsonOnly == true)
        #expect(decoded.defaults.file == "mounted-json")
        #expect(decoded.defaults.exec == "vault")
        #expect(decoded.resolution.maxProviderConcurrency == 6)
        #expect(decoded.resolution.maxRefsPerProvider == 42)
        #expect(decoded.resolution.maxBatchBytes == 2_048)
    }

    @Test
    func openClawConfigDecodesSecretsBlockWithoutBreakingPlaintextProviderFields() throws {
        let json = #"""
        {
          "secrets": {
            "providers": {
              "default": {
                "source": "env",
                "allowlist": ["OPENAI_API_KEY"]
              }
            }
          },
          "models": {
            "openAI": {
              "enabled": true,
              "modelID": "gpt-4.1-mini",
              "apiKey": "sk-plain",
              "baseURL": "https://api.openai.com/v1"
            }
          }
        }
        """#

        let decoded = try JSONDecoder().decode(OpenClawConfig.self, from: Data(json.utf8))

        #expect(decoded.models.openAI.apiKey == "sk-plain")
        #expect(decoded.secrets.defaultProviderAlias(for: .env) == DEFAULT_SECRET_PROVIDER_ALIAS)
        #expect(decoded.secrets.providers["default"] != nil)
    }
}
