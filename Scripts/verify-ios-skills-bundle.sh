#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Examples/iOS/OpenClawiOS/OpenClawiOS.xcodeproj}"
SCHEME="${SCHEME:-OpenClawiOS}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"

BUILD_SETTINGS="$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -showBuildSettings)"

TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/ TARGET_BUILD_DIR = / {print $2; exit}')"
WRAPPER_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/ WRAPPER_NAME = / {print $2; exit}')"

if [[ -z "${TARGET_BUILD_DIR}" || -z "${WRAPPER_NAME}" ]]; then
  echo "Failed to resolve iOS example build output path from xcodebuild settings." >&2
  exit 1
fi

APP_PATH="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
SKILL_FILE="${APP_PATH}/skills/weather/SKILL.md"
WASM_SKILL_FILE="${APP_PATH}/skills/wasm-hello/SKILL.md"
WASM_MODULE_FILE="${APP_PATH}/skills/wasm-hello/module/hello.wasm"

if [[ ! -f "${SKILL_FILE}" ]]; then
  echo "Missing bundled skill file: ${SKILL_FILE}" >&2
  exit 1
fi

if [[ ! -f "${WASM_SKILL_FILE}" ]]; then
  echo "Missing bundled WASM skill file: ${WASM_SKILL_FILE}" >&2
  exit 1
fi

if [[ ! -f "${WASM_MODULE_FILE}" ]]; then
  echo "Missing bundled WASM module file: ${WASM_MODULE_FILE}" >&2
  exit 1
fi

echo "Verified bundled skills at ${SKILL_FILE} and ${WASM_MODULE_FILE}"
