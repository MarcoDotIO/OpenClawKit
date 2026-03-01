#!/usr/bin/env bash
set -euo pipefail

PROJECT="Examples/iOS/OpenClawiOS/OpenClawiOS.xcodeproj"
SCHEME="OpenClawiOS"
DESTINATION="generic/platform=iOS Simulator"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

bash Scripts/verify-ios-skills-bundle.sh
