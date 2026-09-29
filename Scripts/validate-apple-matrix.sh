#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

platform="all"
if [[ "${1:-}" == "--platform" ]]; then
  platform="${2:-all}"
fi

required_platform_tokens=(".iOS(" ".macOS(" ".tvOS(" ".visionOS(" ".watchOS(")
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

status=0

# Lists Swift files under the given roots that match an extended regex.
swift_files_matching() {
  local pattern="$1"
  shift
  grep -ERl --include='*.swift' -e "${pattern}" "$@" 2>/dev/null || true
}

# `@available(anyAppleOS ...)` parses on Swift 6.4 but not on the Swift 6.2 CI toolchain.
any_apple_os_files="$(swift_files_matching 'anyAppleOS' Sources Tests Examples)"
if [[ -n "${any_apple_os_files}" ]]; then
  echo "Use per-OS availability (iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) instead of anyAppleOS:"
  echo "${any_apple_os_files}" | sed 's/^/  /'
  status=1
fi

# 27-only frameworks and symbols must sit behind `#if compiler(>=6.4)` (they do not exist in the
# 26 SDKs) in addition to canImport/platform guards and @available/#available gates.
apple27_pattern='^[[:space:]]*import[[:space:]]+(CoreAI|StateReporting|NowPlaying|MediaIntelligence|MusicUnderstanding|SuggestedActions|TrustInsights|LinkSecurity)\b'
apple27_pattern+='|PrivateCloudComputeLanguageModel|LanguageModelExecutor|SpotlightSearchTool|OCRTool|BarcodeReaderTool'
apple27_pattern+='|VideoAnalyzer|MusicUnderstandingSession|AIModelAsset|SuggestedActionsView'
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  if ! grep -Fq '#if compiler(>=6.4)' "${file}"; then
    echo "27-only API used without a '#if compiler(>=6.4)' guard: ${file}"
    status=1
  fi
done <<<"$(swift_files_matching "${apple27_pattern}" Sources Examples)"

# FoundationModels ships on tvOS/watchOS with the 27 SDKs, but its declarations are unavailable on
# tvOS (and SystemLanguageModel on watchOS), so canImport alone is not a sufficient guard.
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  if ! grep -Eq '!os\(tvOS\)' "${file}"; then
    echo "FoundationModels imported without a '!os(tvOS)' guard: ${file}"
    status=1
  fi
done <<<"$(swift_files_matching '^[[:space:]]*import[[:space:]]+FoundationModels\b' Sources Examples)"
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  if ! grep -Eq '!os\(watchOS\)' "${file}"; then
    echo "SystemLanguageModel used without a '!os(watchOS)' guard: ${file}"
    status=1
  fi
done <<<"$(swift_files_matching 'SystemLanguageModel' Sources)"

# ChatUI views ship on iOS/macOS/visionOS only; these SwiftUI APIs are unavailable on tvOS/watchOS
# (and scrollDismissesKeyboard on visionOS), so every file using them needs a platform guard.
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  if ! grep -Eq '^[[:space:]]*#if[[:space:]].*os\(' "${file}"; then
    echo "ChatUI file uses platform-limited SwiftUI APIs without an os() guard: ${file}"
    status=1
  fi
done <<<"$(swift_files_matching '\.textSelection\(|TextEditor\(|\.scrollDismissesKeyboard\(|PhotosPicker' Sources/OpenClawChatUI)"

# BGTaskScheduler.submitTaskRequest(_:) is the async iOS/tvOS 27 submission API. Every call needs a
# `#if compiler(>=6.4)` guard in its file and an iOS 27.0 availability gate (`@available(iOS 27.0`
# on the enclosing declaration or `#available(iOS 27.0` on the branch) within the preceding
# lines; otherwise the 26 SDKs fail to compile it and iOS 17-26 devices reach a missing symbol.
# Use OpenClawBackgroundTasks.submit(_:) from OpenClawKit, which already gates it.
submit_task_request_window=15
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  # Only code lines count; doc comments that mention the API are fine.
  call_lines="$(grep -nE 'submitTaskRequest\(' "${file}" | grep -vE '^[0-9]+:[[:space:]]*///?' || true)"
  [[ -z "${call_lines}" ]] && continue
  if ! grep -Fq '#if compiler(>=6.4)' "${file}"; then
    echo "submitTaskRequest( used without a '#if compiler(>=6.4)' guard: ${file}"
    status=1
  fi
  while IFS=: read -r line_number _; do
    [[ -z "${line_number}" ]] && continue
    start=$((line_number > submit_task_request_window ? line_number - submit_task_request_window : 1))
    if ! sed -n "${start},${line_number}p" "${file}" | grep -Eq '[@#]available\([^)]*iOS 27\.0'; then
      echo "submitTaskRequest( without an @available(iOS 27.0 / #available(iOS 27.0 gate in the preceding ${submit_task_request_window} lines: ${file}:${line_number}"
      status=1
    fi
  done <<<"${call_lines}"
done <<<"$(swift_files_matching 'submitTaskRequest\(' Sources Examples)"

# OS 27-only availability sites must also be compiled out below Swift 6.4, because CI and SDK
# consumers can build with Xcode 26 (26 SDKs), where the 27-only types do not exist.
if ! python3 Scripts/check-os27-compiler-gates.py Sources Tests Examples; then
  status=1
fi

if [[ ${status} -ne 0 ]]; then
  exit 1
fi

echo "Apple matrix static validation passed (platform=${platform})."
