#!/usr/bin/env bash
# Fast per-SDK typecheck of the Apple-only OpenClawKit sources at the package's minimum
# deployment targets, without SwiftPM resolution or a full xcodebuild.
#
# Usage: Scripts/typecheck-apple-sdks.sh [ios|tvos|watchos|visionos|macos|all] [--allow-warnings]
#        (default: all)
#
# For each SDK it:
#   1. emits every package module OpenClawKit depends on, in dependency order, for the
#      minimum-OS triple: OpenClawProtocol, OpenClawCore, OpenClawNativeState, OpenClawGateway,
#      OpenClawMedia, OpenClawModels, OpenClawSkills, OpenClawAgents, OpenClawMemory,
#      OpenClawMCP, OpenClawPlugins and OpenClawChannels. Third-party packages (swift-crypto,
#      OpenAIKit, WasmKit, swift-system) are not resolved; the package sources import them
#      behind `#if canImport(...)`, so the Apple-framework branches are the ones checked.
#      Dependency modules skip non-inlinable function bodies to stay fast; the protocol and core
#      modules are emitted in full because OpenClawKit leans on their inlinable helpers.
#   2. typechecks every Sources/OpenClawKit file (including the OpenClawKit.swift facade that
#      re-exports the modules above) against them with -warnings-as-errors, using a one-line
#      `Bundle.module` stub in place of the SwiftPM resource accessor;
#   3. for iOS, repeats step 2 with -application-extension to catch APIs that are unavailable
#      in app extensions (share extensions link OpenClawKit).
#
# This catches availability, platform-guard and Int-width (watchOS arm64_32) regressions in
# OpenClawKit early. It does not run SIL diagnostics (region isolation) or link anything:
# Scripts/build-apple-platforms.sh remains the authoritative full build of every product.
#
# Environment:
#   OPENCLAW_TYPECHECK_KEEP=1   keep .build/typecheck-apple-sdks after a successful run.
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

# "<module> <mode>" rows in dependency order (see Package.swift). `full` emits the module with
# every function body typechecked; `interface` skips non-inlinable bodies (faster, and enough to
# typecheck OpenClawKit against the module's public surface).
module_plan() {
  cat <<'EOF'
OpenClawProtocol full
OpenClawCore full
OpenClawNativeState full
OpenClawGateway interface
OpenClawMedia interface
OpenClawModels interface
OpenClawSkills interface
OpenClawAgents interface
OpenClawMemory interface
OpenClawMCP interface
OpenClawPlugins interface
OpenClawChannels interface
EOF
}

# Fails loudly when OpenClawKit's target gains a package dependency this script does not emit.
check_module_plan() {
  local planned kit_deps missing=""
  planned="$(module_plan | awk '{print $1}')"
  kit_deps="$(grep -rhoE --include='*.swift' '^[[:space:]]*(@_exported[[:space:]]+|@preconcurrency[[:space:]]+)?import[[:space:]]+OpenClaw[A-Za-z]+' \
    "${ROOT_DIR}/Sources/OpenClawKit" | awk '{print $NF}' | sort -u)"
  local dep
  for dep in ${kit_deps}; do
    [[ "${dep}" == "OpenClawKit" ]] && continue
    if ! grep -qx "${dep}" <<<"${planned}"; then
      missing="${missing:+${missing} }${dep}"
    fi
  done
  if [[ -n "${missing}" ]]; then
    echo "error: Sources/OpenClawKit imports module(s) this script does not emit: ${missing}" >&2
    echo "       add them to module_plan() in $(basename "$0") in dependency order." >&2
    exit 1
  fi
}

module_sources() {
  find "${ROOT_DIR}/Sources/$1" -name '*.swift' -print0 | sort -z
}

kit_sources=()
while IFS= read -r -d '' file; do
  kit_sources+=("${file}")
done < <(module_sources OpenClawKit)

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

emit_module() {
  local platform="$1" sdk="$2" sdk_path="$3" triple="$4" out_dir="$5" module="$6" mode="$7"
  local log="${out_dir}/${module}.log" sources=() extra=()
  while IFS= read -r -d '' file; do
    sources+=("${file}")
  done < <(module_sources "${module}")
  if [[ ${#sources[@]} -eq 0 ]]; then
    echo "    [${platform}] ${module}: no sources found" >&2
    return 1
  fi
  if [[ "${mode}" == "interface" ]]; then
    extra+=(-Xfrontend -experimental-skip-non-inlinable-function-bodies)
  fi
  if ! xcrun --sdk "${sdk}" swiftc \
    -emit-module \
    -module-name "${module}" \
    -parse-as-library \
    -target "${triple}" \
    -sdk "${sdk_path}" \
    "${common_flags[@]}" \
    ${extra[@]+"${extra[@]}"} \
    -I "${out_dir}" \
    -emit-module-path "${out_dir}/${module}.swiftmodule" \
    "${sources[@]}" >"${log}" 2>&1; then
    echo "    [${platform}] ${module} FAILED (${triple})"
    report "${log}"
    return 1
  fi
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

  local module mode started
  started=${SECONDS}
  while read -r module mode; do
    emit_module "${platform}" "${sdk}" "${sdk_path}" "${triple}" "${out_dir}" "${module}" "${mode}" || return 1
  done < <(module_plan)
  echo "    [${platform}] emitted $(module_plan | wc -l | tr -d ' ') dependency modules in $((SECONDS - started))s"

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
      ${extra[@]+"${extra[@]}"} \
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

check_module_plan

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
  echo "Typecheck failed for: ${failed} (logs in ${WORK_DIR#"${ROOT_DIR}/"})"
  exit 1
fi
if [[ "${OPENCLAW_TYPECHECK_KEEP:-0}" != "1" ]]; then
  rm -rf "${WORK_DIR}"
fi
echo "Typecheck passed (${requested})."
