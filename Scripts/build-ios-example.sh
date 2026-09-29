#!/usr/bin/env bash
# Builds the iOS example app (Examples/iOS) for the generic iOS Simulator and verifies that the
# bundled example skills are copied into the app.
#
# DerivedData goes to .build/xcode-example-ios (override with OPENCLAW_EXAMPLE_DERIVED_DATA) so the
# build is reproducible and easy to clean (`rm -rf .build/xcode-*`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PROJECT="Examples/iOS/OpenClawiOS/OpenClawiOS.xcodeproj"
SCHEME="OpenClawiOS"
DESTINATION="generic/platform=iOS Simulator"
DERIVED_DATA_PATH="${OPENCLAW_EXAMPLE_DERIVED_DATA:-${ROOT_DIR}/.build/xcode-example-ios}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

DERIVED_DATA_PATH="$DERIVED_DATA_PATH" bash Scripts/verify-ios-skills-bundle.sh
