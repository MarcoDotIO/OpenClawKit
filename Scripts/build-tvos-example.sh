#!/usr/bin/env bash
set -euo pipefail

PROJECT="Examples/tvOS/OpenClawtvOS/OpenClawtvOS.xcodeproj"
SCHEME="OpenClawtvOS"
DESTINATION="generic/platform=tvOS Simulator"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
