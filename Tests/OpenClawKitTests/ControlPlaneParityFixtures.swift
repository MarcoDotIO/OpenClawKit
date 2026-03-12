import OpenClawCore

enum ControlPlaneParityFixtures {
    static let referenceCommit = "62a71361a98d87b2b35a45d0f5ab7627eeea0916"

    static let agentDefaultsConfigJSON = """
    {
      "agents": {
        "defaultAgentID": "ops",
        "workspaceRoot": "./workspace-ops",
        "thinkingLevel": "adaptive",
        "verboseLevel": "full",
        "reasoningLevel": "stream",
        "responseUsage": "tokens",
        "elevatedLevel": "ask",
        "groupActivation": "always",
        "groupActivationNeedsSystemIntro": true,
        "sendPolicy": "allow",
        "modelOverride": "openai/gpt-5.4",
        "execHost": "node",
        "execSecurity": "allowlist",
        "execAsk": "on-miss",
        "execNode": "node20"
      }
    }
    """

    static let sessionPatchRequestJSON = """
    {
      "type": "req",
      "id": "fixture-session-patch",
      "method": "sessions.patch",
      "params": {
        "key": "primary",
        "label": "Primary Ops Session",
        "modelOverride": "openai/gpt-5.4",
        "thinkingLevel": "adaptive",
        "verboseLevel": "full",
        "reasoningLevel": "stream",
        "responseUsage": "tokens",
        "elevatedLevel": "ask",
        "groupActivation": "always",
        "sendPolicy": "allow",
        "execHost": "node",
        "execSecurity": "allowlist",
        "execAsk": "on-miss",
        "execNode": "node20"
      }
    }
    """

    static let browserRequestJSON = """
    {
      "type": "req",
      "id": "fixture-browser-request",
      "method": "browser.request",
      "params": {
        "method": "POST",
        "path": "/tabs",
        "query": {
          "profile": "default"
        },
        "body": {
          "openInBackground": true
        },
        "timeoutMs": 3000,
        "workspaceRoot": "/tmp/workspace",
        "spawnedWorkspaceRoot": "/tmp/workspace/spawned"
      }
    }
    """

    static let llmTaskArgumentsJSON = """
    {
      "prompt": "Summarize the incident",
      "input": {
        "ticket": "INC-42",
        "severity": 2
      },
      "schema": {
        "type": "object",
        "required": ["summary"],
        "properties": {
          "summary": {
            "type": "string"
          }
        }
      },
      "provider": "openai-codex",
      "model": "gpt-5.4",
      "thinking": "adaptive",
      "authProfileId": "work-profile",
      "temperature": 0.25,
      "maxTokens": 120,
      "timeoutMs": 2500
    }
    """

    static let blueBubblesWebhookJSON = """
    {
      "chatGuid": "iMessage;-;+15551234567",
      "from": "+15557654321",
      "text": "hello from bluebubbles",
      "isFromMe": false,
      "attachments": [
        {
          "mimeType": "image/png",
          "base64Data": "aGVsbG8=",
          "fileName": "hello.png"
        }
      ]
    }
    """

    static let thinkingAliases: [(raw: String, normalized: ThinkLevel)] = [
        ("auto", .adaptive),
        ("x-high", .xhigh),
        ("think-hard", .low),
        ("harder", .medium),
        ("ultra", .high),
    ]
}
