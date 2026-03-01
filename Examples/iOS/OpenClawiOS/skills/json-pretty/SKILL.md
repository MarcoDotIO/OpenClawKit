---
name: json-pretty
description: Pretty-print and key-sort JSON payloads for readability.
entrypoint: scripts/json-pretty.js
primaryEnv: node
user-invocable: true
disable-model-invocation: false
---

Use this skill when the user asks to format or normalize raw JSON.

Input contract (JSON or plain text):
- `json` (string or object): JSON value to format. If omitted, the raw input string is parsed.

Output contract (JSON):
- `pretty`: Pretty-printed JSON string with stable key order.

Example:
- `/json-pretty {"json":{"z":1,"a":{"k":2,"b":1}}}`
