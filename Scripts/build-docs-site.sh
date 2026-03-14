#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/docc-derived-data}"
MERGED_ARCHIVE_PATH="${DOCC_MERGED_ARCHIVE_PATH:-${ROOT_DIR}/.build/OpenClawKit.doccarchive}"
SITE_OUTPUT_PATH="${DOCC_STATIC_SITE_OUTPUT_PATH:-${ROOT_DIR}/.build/docc-static-site}"
HOSTING_BASE_PATH="${DOCC_HOSTING_BASE_PATH:-/OpenClawKit}"
SCHEME="${DOCC_SCHEME:-OpenClawKit-Package}"
ROOT_INDEX_PATH="${SITE_OUTPUT_PATH}/index.html"
FIRST_PARTY_MODULES=(
    OpenClawProtocol
    OpenClawCore
    OpenClawGateway
    OpenClawAgents
    OpenClawPlugins
    OpenClawChannels
    OpenClawMemory
    OpenClawMedia
    OpenClawModels
    OpenClawSkills
    OpenClawKit
    OpenClawChatUI
)

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild is required to generate DocC archives." >&2
    exit 1
fi

rm -rf "${DERIVED_DATA_PATH}" "${MERGED_ARCHIVE_PATH}" "${SITE_OUTPUT_PATH}"

xcodebuild docbuild \
    -scheme "${SCHEME}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO

archives=()
for module in "${FIRST_PARTY_MODULES[@]}"; do
    archive_path="${DERIVED_DATA_PATH}/Build/Products/Debug/${module}.doccarchive"
    if [[ ! -d "${archive_path}" ]]; then
        echo "Missing DocC archive for ${module}: ${archive_path}" >&2
        exit 1
    fi
    archives+=("${archive_path}")
done

xcrun docc merge \
    "${archives[@]}" \
    --output-path "${MERGED_ARCHIVE_PATH}" \
    --synthesized-landing-page-name OpenClawKit \
    --synthesized-landing-page-kind Package \
    --synthesized-landing-page-topics-style detailedGrid

xcrun docc process-archive transform-for-static-hosting \
    "${MERGED_ARCHIVE_PATH}" \
    --output-path "${SITE_OUTPUT_PATH}" \
    --hosting-base-path "${HOSTING_BASE_PATH}"

docs_landing_path="${HOSTING_BASE_PATH%/}/documentation/openclawkit/"
cat > "${ROOT_INDEX_PATH}" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0; url=${docs_landing_path}">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenClawKit Documentation</title>
  <script>location.replace("${docs_landing_path}");</script>
</head>
<body>
  <p>Redirecting to <a href="${docs_landing_path}">OpenClawKit Documentation</a>...</p>
</body>
</html>
EOF

test -f "${ROOT_INDEX_PATH}"
test -d "${SITE_OUTPUT_PATH}/documentation/openclawkit"
