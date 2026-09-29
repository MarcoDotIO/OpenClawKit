#!/usr/bin/env bash
# Builds the tvOS example app (Examples/tvOS) for the generic tvOS Simulator.
#
# DerivedData goes to .build/xcode-example-tvos (override with OPENCLAW_EXAMPLE_DERIVED_DATA).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PROJECT="Examples/tvOS/OpenClawtvOS/OpenClawtvOS.xcodeproj"
SCHEME="OpenClawtvOS"
DESTINATION="generic/platform=tvOS Simulator"
DERIVED_DATA_PATH="${OPENCLAW_EXAMPLE_DERIVED_DATA:-${ROOT_DIR}/.build/xcode-example-tvos}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
