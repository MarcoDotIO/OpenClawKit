---
name: wasm-hello
description: Run a bundled WASM/WASI smoke test module.
entrypoint: module/hello.wasm
primaryEnv: wasi
user-invocable: true
requires-explicit-invocation: true
disable-model-invocation: false
---

Use this skill to validate embedded WASM execution in the iOS example app.

Input contract:
- Optional plain text payload.

Output contract:
- Deterministic text printed by the bundled WASI module.

Example:
- `/wasm-hello smoke-test`
