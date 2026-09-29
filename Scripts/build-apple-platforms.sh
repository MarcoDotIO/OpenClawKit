#!/usr/bin/env bash
# Builds every OpenClawKit package product for one or more Apple platforms.
#
# Usage: Scripts/build-apple-platforms.sh [ios|tvos|watchos|visionos|macos|all]
#
# - ios/tvos/watchos/visionos run `xcodebuild -scheme OpenClawKit-Package` against
#   the matching `generic/platform=<P>` destination (DerivedData under .build/xcode-<p>).
# - macos runs `swift build -Xswiftc -warnings-as-errors`.
#
# Each platform's full log is written to .build/logs/build-<p>.log. A concise summary of
# error lines is printed per platform and the script exits non-zero if any platform fails.
# Set OPENCLAW_XCODEBUILD_EXTRA_ARGS to pass extra arguments to xcodebuild.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SCHEME="${OPENCLAW_SCHEME:-OpenClawKit-Package}"
LOG_DIR="${ROOT_DIR}/.build/logs"
MAX_ERROR_LINES="${OPENCLAW_MAX_ERROR_LINES:-40}"

usage() {
  echo "Usage: $(basename "$0") [ios|tvos|watchos|visionos|macos|all]" >&2
}

requested="$(printf '%s' "${1:-all}" | tr '[:upper:]' '[:lower:]')"
case "${requested}" in
  all) platforms=(macos ios tvos watchos visionos) ;;
  ios|tvos|watchos|visionos|macos) platforms=("${requested}") ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

destination_for() {
  case "$1" in
    ios) echo "generic/platform=iOS" ;;
    tvos) echo "generic/platform=tvOS" ;;
    watchos) echo "generic/platform=watchOS" ;;
    visionos) echo "generic/platform=visionOS" ;;
  esac
}

mkdir -p "${LOG_DIR}"

# Strips ANSI colors and OSC-8 hyperlinks (swift build colors diagnostics even when redirected)
# and makes paths repo-relative.
clean_log() {
  perl -pe 's/\e\]8;;.*?\e\\//g; s/\e\[[0-9;]*[A-Za-z]//g' "$1" | sed -E "s#${ROOT_DIR}/##g"
}

# Prints de-duplicated compiler/linker/xcodebuild error lines from a log file.
summarize_errors() {
  clean_log "$1" \
    | grep -E '^[^[:space:]|].*:[0-9]+(:[0-9]+)?: (fatal )?error:|^(fatal )?error:|^xcodebuild: error:|^ld: |\*\* BUILD FAILED \*\*' \
    | grep -v 'failed with a nonzero exit code' \
    | cut -c1-240 \
    | awk '!seen[$0]++' \
    | head -n "${MAX_ERROR_LINES}"
}

# Prints this package's source warning lines. Warnings from dependency checkouts (.build/...)
# and dependency manifest deprecations (`warning: '<package>': .../Package.swift`) are skipped.
summarize_warnings() {
  clean_log "$1" \
    | grep -E '^[^[:space:]|].*:[0-9]+:[0-9]+: warning:' \
    | grep -v -e "^warning: '" -e '^\.build/' \
    | cut -c1-240 \
    | awk '!seen[$0]++' \
    | head -n "${MAX_ERROR_LINES}"
}

build_platform() {
  local platform="$1"
  local log_file="${LOG_DIR}/build-${platform}.log"
  local status=0

  if [[ "${platform}" == "macos" ]]; then
    echo "==> [macos] swift build -Xswiftc -warnings-as-errors"
    swift build -Xswiftc -warnings-as-errors >"${log_file}" 2>&1 || status=$?
  else
    local destination
    destination="$(destination_for "${platform}")"
    echo "==> [${platform}] xcodebuild -scheme ${SCHEME} -destination ${destination}"
    # shellcheck disable=SC2086
    xcodebuild \
      -scheme "${SCHEME}" \
      -configuration Debug \
      -destination "${destination}" \
      -derivedDataPath ".build/xcode-${platform}" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      ${OPENCLAW_XCODEBUILD_EXTRA_ARGS:-} \
      build >"${log_file}" 2>&1 || status=$?
  fi

  local warnings
  warnings="$(summarize_warnings "${log_file}")"
  if [[ ${status} -eq 0 ]]; then
    echo "    [${platform}] OK (log: ${log_file#"${ROOT_DIR}/"})"
  else
    echo "    [${platform}] FAILED with exit code ${status} (log: ${log_file#"${ROOT_DIR}/"})"
    local errors
    errors="$(summarize_errors "${log_file}")"
    if [[ -n "${errors}" ]]; then
      echo "${errors}" | sed 's/^/      /'
    else
      echo "      (no error lines matched; last lines of the log follow)"
      clean_log "${log_file}" | tail -n 20 | sed 's/^/      /'
    fi
  fi
  if [[ -n "${warnings}" ]]; then
    echo "      source warnings:"
    echo "${warnings}" | sed 's/^/        /'
  fi
  return "${status}"
}

# Plain strings instead of arrays: macOS ships bash 3.2, where expanding an empty array
# under `set -u` is an error.
failed=""
succeeded=""
for platform in "${platforms[@]}"; do
  if build_platform "${platform}"; then
    succeeded="${succeeded:+${succeeded} }${platform}"
  else
    failed="${failed:+${failed} }${platform}"
  fi
done

echo
echo "Summary: succeeded: ${succeeded:-none}; failed: ${failed:-none}"
if [[ -n "${failed}" ]]; then
  exit 1
fi
