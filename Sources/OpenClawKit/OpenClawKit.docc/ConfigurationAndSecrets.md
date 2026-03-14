# Configuration and Secrets

`OpenClawKit` keeps configuration in ``OpenClawConfig`` and treats secret
material as a first-class concern through ``SecretInput``, ``SecretRef``, and
``CredentialStore``.

## Plaintext or Secret References

Secret-bearing fields accept either a plaintext value or a structured secret
reference. Environment placeholders such as `"${OPENAI_API_KEY}"` decode into a
``SecretRef`` automatically.

```json
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
    "providers": {
      "openai": {
        "enabled": true,
        "auth": "api-key",
        "apiKey": "${OPENAI_API_KEY}"
      }
    }
  }
}
```

## Persistence

Use ``OpenClawSDK/loadConfig(from:cacheTTLms:)`` and
``OpenClawSDK/saveConfig(_:to:)`` for file-backed JSON configuration, and back
auth material with a concrete ``CredentialStore`` such as
``KeychainCredentialStore`` or ``FileCredentialStore`` depending on platform
and deployment needs.

## Related Symbols

- ``OpenClawConfig``
- ``SecretInput``
- ``SecretRef``
- ``SecretsConfig``
- ``CredentialStore``
