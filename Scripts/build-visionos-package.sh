#!/usr/bin/env bash
set -euo pipefail

SCHEME="OpenClawKit"
DESTINATION="generic/platform=visionOS"
DERIVED_DATA_PATH=".build/xcode-visionos"

xcodebuild \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
