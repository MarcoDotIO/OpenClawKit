#!/usr/bin/env bash
# Fast per-SDK typecheck of the Apple-only OpenClawKit sources at the package's minimum
# deployment targets, without SwiftPM resolution or a full xcodebuild.
#
# Usage: Scripts/typecheck-apple-sdks.sh [ios|tvos|watchos|visionos|macos|all] [--allow-warnings]
#        (default: all)
#
# For each SDK it:
#   1. emits OpenClawProtocol and OpenClawCore modules (Sources/OpenClawProtocol, Sources/OpenClawCore)
#      for the minimum-OS triple (OpenClawKit files such as the StateReporting bridge use Core types);
#   2. typechecks Sources/OpenClawKit (minus the OpenClawKit.swift facade, which re-exports the
#      other package modules) against it with -warnings-as-errors, using a one-line
#      `Bundle.module` stub in place of the SwiftPM resource accessor;
#   3. for iOS, repeats step 2 with -application-extension to catch APIs that are unavailable
#      in app extensions (share extensions link OpenClawKit).
#
# This takes seconds and catches availability, platform-guard and Int-width (watchOS arm64_32)
# regressions early. Scripts/build-apple-platforms.sh remains the authoritative full build of
# every product.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

WORK_DIR="${ROOT_DIR}/.build/typecheck-apple-sdks"
warnings_as_errors=1
requested="all"
for arg in "$@"; do
  case "${arg}" in
    --allow-warnings) warnings_as_errors=0 ;;
    ios|tvos|watchos|visionos|macos|all) requested="${arg}" ;;
    -h|--help)
      echo "Usage: $(basename "$0") [ios|tvos|watchos|visionos|macos|all] [--allow-warnings]"
      exit 0
      ;;
    *)
      echo "Usage: $(basename "$0") [ios|tvos|watchos|visionos|macos|all] [--allow-warnings]" >&2
      exit 2
      ;;
  esac
done

# "<platform> <sdk> <triple>" rows; minimum deployment targets must match Package.swift.
matrix() {
  cat <<'EOF'
ios iphoneos arm64-apple-ios17.0
macos macosx arm64-apple-macos14.0
tvos appletvos arm64-apple-tvos17.0
watchos watchos arm64_32-apple-watchos10.0
visionos xros arm64-apple-xros26.0
EOF
}

protocol_sources=()
while IFS= read -r -d '' file; do
  protocol_sources+=("${file}")
done < <(find "${ROOT_DIR}/Sources/OpenClawProtocol" -name '*.swift' -print0 | sort -z)

core_sources=()
while IFS= read -r -d '' file; do
  core_sources+=("${file}")
done < <(find "${ROOT_DIR}/Sources/OpenClawCore" -name '*.swift' -print0 | sort -z)

kit_sources=()
while IFS= read -r -d '' file; do
  kit_sources+=("${file}")
done < <(find "${ROOT_DIR}/Sources/OpenClawKit" -name '*.swift' ! -name 'OpenClawKit.swift' -print0 | sort -z)

common_flags=(-swift-version 6 -enable-upcoming-feature StrictConcurrency)

# Prints repo-relative diagnostics without ANSI colors.
report() {
  perl -pe 's/\e\]8;;.*?\e\\//g; s/\e\[[0-9;]*[A-Za-z]//g' "$1" \
    | sed -E "s#${ROOT_DIR}/##g" \
    | grep -E ':[0-9]+:[0-9]+: (error|warning):|^error:' \
    | awk '!seen[$0]++' \
    | head -n 40 \
    | sed 's/^/      /'
}

typecheck_platform() {
  local platform="$1" sdk="$2" triple="$3"
  local sdk_path out_dir stub log status=0
  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)" || return 1
  out_dir="${WORK_DIR}/${platform}"
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"

  stub="${out_dir}/BundleModuleStub.swift"
  printf 'import Foundation\n\nextension Foundation.Bundle {\n    static let module = Bundle.main\n}\n' >"${stub}"

  log="${out_dir}/OpenClawProtocol.log"
  if ! xcrun --sdk "${sdk}" swiftc \
    -emit-module \
    -module-name OpenClawProtocol \
    -parse-as-library \
    -target "${triple}" \
    -sdk "${sdk_path}" \
    "${common_flags[@]}" \
    -emit-module-path "${out_dir}/OpenClawProtocol.swiftmodule" \
    "${protocol_sources[@]}" >"${log}" 2>&1; then
    echo "    [${platform}] OpenClawProtocol FAILED (${triple})"
    report "${log}"
    return 1
  fi

  log="${out_dir}/OpenClawCore.log"
  if ! xcrun --sdk "${sdk}" swiftc \
    -emit-module \
    -module-name OpenClawCore \
    -parse-as-library \
    -target "${triple}" \
    -sdk "${sdk_path}" \
    "${common_flags[@]}" \
    -I "${out_dir}" \
    -emit-module-path "${out_dir}/OpenClawCore.swiftmodule" \
    "${core_sources[@]}" >"${log}" 2>&1; then
    echo "    [${platform}] OpenClawCore FAILED (${triple})"
    report "${log}"
    return 1
  fi

  local variants=("default")
  if [[ "${platform}" == "ios" ]]; then
    variants+=("application-extension")
  fi

  local variant
  for variant in "${variants[@]}"; do
    local extra=()
    if [[ ${warnings_as_errors} -eq 1 ]]; then
      extra+=(-warnings-as-errors)
    fi
    if [[ "${variant}" == "application-extension" ]]; then
      extra+=(-application-extension)
    fi
    log="${out_dir}/OpenClawKit-${variant}.log"
    if xcrun --sdk "${sdk}" swiftc \
      -typecheck \
      -module-name OpenClawKit \
      -parse-as-library \
      -target "${triple}" \
      -sdk "${sdk_path}" \
      "${common_flags[@]}" \
      "${extra[@]}" \
      -I "${out_dir}" \
      "${kit_sources[@]}" \
      "${stub}" >"${log}" 2>&1; then
      echo "    [${platform}] OpenClawKit ${variant}: OK (${triple})"
    else
      echo "    [${platform}] OpenClawKit ${variant}: FAILED (${triple})"
      report "${log}"
      status=1
    fi
  done
  return "${status}"
}

failed=""
while read -r platform sdk triple; do
  if [[ "${requested}" != "all" && "${requested}" != "${platform}" ]]; then
    continue
  fi
  if ! typecheck_platform "${platform}" "${sdk}" "${triple}"; then
    failed="${failed:+${failed} }${platform}"
  fi
done < <(matrix)

echo
if [[ -n "${failed}" ]]; then
  echo "Typecheck failed for: ${failed}"
  exit 1
fi
echo "Typecheck passed (${requested})."
