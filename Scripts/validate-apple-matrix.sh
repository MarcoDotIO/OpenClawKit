#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

platform="all"
if [[ "${1:-}" == "--platform" ]]; then
  platform="${2:-all}"
fi

required_platform_tokens=(".iOS(" ".macOS(" ".tvOS(" ".watchOS(")
for token in "${required_platform_tokens[@]}"; do
  if ! grep -Fq "${token}" "Package.swift"; then
    echo "Missing platform declaration token '${token}' in Package.swift"
    exit 1
  fi
done

required_share_extension_files=(
  "Examples/iOS/OpenClawiOS/OpenClawShareExtension/AskOpenClawShareViewController.swift"
  "Examples/iOS/OpenClawiOS/OpenClawShareExtension/Info.plist"
  "Examples/iOS/OpenClawiOS/OpenClawShareExtension/README.md"
  "Examples/iOS/OpenClawiOS/OpenClawiOS/SharePromptInbox.swift"
)
for path in "${required_share_extension_files[@]}"; do
  if [[ ! -f "${path}" ]]; then
    echo "Missing share-extension artifact: ${path}"
    exit 1
  fi
done

# Ensure iOS 26-only APIs stay availability-gated.
if grep -ERq "BGContinuedProcessingTask|BGContinuedProcessingTaskRequest" "Examples/iOS/OpenClawiOS/OpenClawiOS"; then
  if ! grep -ERq "@available\\(iOS 26\\.0, \\*\\)" "Examples/iOS/OpenClawiOS/OpenClawiOS"; then
    echo "Detected iOS 26 APIs without availability guard."
    exit 1
  fi
fi

echo "Apple matrix static validation passed (platform=${platform})."
