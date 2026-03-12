---
name: calculator
description: Evaluate simple arithmetic expressions or operation payloads.
entrypoint: scripts/calculator.js
primaryEnv: node
user-invocable: true
disable-model-invocation: false
---

Use this skill when the user asks for arithmetic that can be computed directly.

Input contract (JSON or plain text):
- `expression` (string): Arithmetic expression with numbers, parentheses, and `+ - * /`.
- OR `operation` (`add|subtract|multiply|divide`) and `values` (array of numbers).

Output contract (JSON):
- `result`: Numeric result.
- `mode`: `expression` or `operation`.

Examples:
- `/calculator {"expression":"(12 + 8) / 4"}`
- `/calculator {"operation":"multiply","values":[3,7,2]}`
