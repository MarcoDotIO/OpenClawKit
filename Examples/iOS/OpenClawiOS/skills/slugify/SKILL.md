---
name: slugify
description: Convert arbitrary text into a URL-safe slug.
entrypoint: scripts/slugify.js
primaryEnv: node
user-invocable: true
disable-model-invocation: false
---

Use this skill when the user asks to normalize a title, headline, or phrase into a slug.

Input contract (JSON or plain text):
- `text` (string): Source string to convert.

Output contract (JSON):
- `slug`: URL-safe slug value.
- `source`: Original normalized source string.

Example:
- `/slugify {"text":"OpenClaw 2026.1.5 Release Notes!"}`
