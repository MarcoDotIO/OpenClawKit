#!/usr/bin/env bash
set -euo pipefail

PROJECT="Examples/iOS/OpenClawiOS/OpenClawiOS.xcodeproj"
SCHEME="OpenClawiOS"
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit}')}"
if [[ -z "${SIMULATOR_NAME}" ]]; then
  echo "No available iPhone simulator found for iOS example tests." >&2
  exit 1
fi
DESTINATION="platform=iOS Simulator,name=${SIMULATOR_NAME}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test \
  -only-testing:OpenClawiOSTests \
  -only-testing:OpenClawiOSUITests
