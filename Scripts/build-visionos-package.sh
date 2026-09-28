#!/usr/bin/env bash
# Builds every package product (scheme OpenClawKit-Package, including OpenClawChatUI) for
# generic visionOS. Kept for CI compatibility; see Scripts/build-apple-platforms.sh.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-apple-platforms.sh" visionos
