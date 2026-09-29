#!/usr/bin/env bash
# Runs the iOS example unit and UI tests on an available iPhone simulator.
#
# IOS_SIMULATOR_NAME selects the simulator (default: the first available iPhone). DerivedData goes
# to .build/xcode-example-ios-tests (override with OPENCLAW_EXAMPLE_DERIVED_DATA).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PROJECT="Examples/iOS/OpenClawiOS/OpenClawiOS.xcodeproj"
SCHEME="OpenClawiOS"
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit}')}"
if [[ -z "${SIMULATOR_NAME}" ]]; then
  echo "No available iPhone simulator found for iOS example tests." >&2
  exit 1
fi
DESTINATION="platform=iOS Simulator,name=${SIMULATOR_NAME}"
DERIVED_DATA_PATH="${OPENCLAW_EXAMPLE_DERIVED_DATA:-${ROOT_DIR}/.build/xcode-example-ios-tests}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test \
  -only-testing:OpenClawiOSTests \
  -only-testing:OpenClawiOSUITests
