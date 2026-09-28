#!/usr/bin/env bash
# Verifies that Apple frameworks which do not exist at the package's minimum deployment
# targets (iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 26) are only weak-linked.
#
# Usage: Scripts/check-apple-weak-links.sh [ios|tvos|watchos|visionos|macos|all] [--no-build]
#        (default platform: ios)
#
# How it works:
#   1. Builds scheme OpenClawKit-Package with xcodebuild for `generic/platform=<P>`
#      (DerivedData under .build/xcode-<p>, shared with Scripts/build-apple-platforms.sh;
#      skipped with --no-build).
#   2. Links every per-target object file (`Build/Products/Debug-<sdk>/*.o`, i.e. all package
#      products plus their dependencies) into a throwaway probe dylib with `swiftc`, using the
#      package's minimum deployment target. This is what an app linking the package gets:
#      the system frameworks come in through Swift/Clang autolinking.
#   3. Reads the probe's load commands with `otool -l`. Any watched framework that appears as
#      LC_LOAD_DYLIB (strong) fails the check, and the strongly referenced symbols are listed
#      with `nm -m`. A strong load of a framework that is missing at runtime makes dyld abort
#      at launch on older OS versions (for example iOS 17-26 for 27-only frameworks).
#
# A framework is weak-linked only when EVERY symbol referenced from it is availability-gated
# (`@available`/`#available` with a version newer than the deployment target). Frameworks that
# are not linked at all pass.
#
# Environment:
#   OPENCLAW_WEAK_LINK_FRAMEWORKS  space-separated framework names to watch (overrides defaults)
#   OPENCLAW_SCHEME                scheme to build (default: OpenClawKit-Package)
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SCHEME="${OPENCLAW_SCHEME:-OpenClawKit-Package}"
WORK_DIR="${ROOT_DIR}/.build/weak-link-probe"
LOG_DIR="${ROOT_DIR}/.build/logs"

# Frameworks introduced after the package floors. FoundationModels ships with the 26 SDKs;
# the rest are new in the 27 SDKs.
DEFAULT_27_FRAMEWORKS="CoreAI StateReporting NowPlaying MediaIntelligence MusicUnderstanding SuggestedActions TrustInsights LinkSecurity"
DEFAULT_26_FRAMEWORKS="FoundationModels"

usage() {
  echo "Usage: $(basename "$0") [ios|tvos|watchos|visionos|macos|all] [--no-build]" >&2
}

requested="ios"
build=1
for arg in "$@"; do
  case "${arg}" in
    --no-build) build=0 ;;
    -h|--help) usage; exit 0 ;;
    ios|tvos|watchos|visionos|macos|all) requested="${arg}" ;;
    *) usage; exit 2 ;;
  esac
done

case "${requested}" in
  all) platforms=(ios tvos watchos visionos macos) ;;
  *) platforms=("${requested}") ;;
esac

# Per-platform settings: SDK name, products directory suffix, destination, link triples.
platform_sdk() {
  case "$1" in
    ios) echo "iphoneos" ;;
    tvos) echo "appletvos" ;;
    watchos) echo "watchos" ;;
    visionos) echo "xros" ;;
    macos) echo "macosx" ;;
  esac
}

platform_products_dir() {
  case "$1" in
    macos) echo "Debug" ;;
    *) echo "Debug-$(platform_sdk "$1")" ;;
  esac
}

platform_destination() {
  case "$1" in
    ios) echo "generic/platform=iOS" ;;
    tvos) echo "generic/platform=tvOS" ;;
    watchos) echo "generic/platform=watchOS" ;;
    visionos) echo "generic/platform=visionOS" ;;
    macos) echo "generic/platform=macOS" ;;
  esac
}

# Minimum deployment targets must match Package.swift `platforms:`.
platform_triples() {
  case "$1" in
    ios) echo "arm64-apple-ios17.0" ;;
    tvos) echo "arm64-apple-tvos17.0" ;;
    watchos) echo "arm64_32-apple-watchos10.0 arm64-apple-watchos10.0" ;;
    visionos) echo "arm64-apple-xros26.0" ;;
    macos) echo "arm64-apple-macos14.0" ;;
  esac
}

watched_frameworks() {
  if [[ -n "${OPENCLAW_WEAK_LINK_FRAMEWORKS:-}" ]]; then
    echo "${OPENCLAW_WEAK_LINK_FRAMEWORKS}"
    return
  fi
  case "$1" in
    # FoundationModels already exists at the visionOS 26 floor, so it may be strong there.
    visionos) echo "${DEFAULT_27_FRAMEWORKS}" ;;
    *) echo "${DEFAULT_26_FRAMEWORKS} ${DEFAULT_27_FRAMEWORKS}" ;;
  esac
}

# Prints "<LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|...> <install name>" for each dylib load command.
load_commands() {
  otool -l "$1" | awk '
    $1 == "cmd" { cmd = $2 }
    $1 == "name" && cmd ~ /^LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD|LOAD_UPWARD)_DYLIB$/ { print cmd, $2 }
  '
}

# Demangles Swift symbols on stdin when swift-demangle is available.
demangle() {
  if xcrun --find swift-demangle >/dev/null 2>&1; then
    xcrun swift-demangle --simplified
  else
    cat
  fi
}

build_package() {
  local platform="$1"
  local log_file="${LOG_DIR}/weak-link-build-${platform}.log"
  echo "==> [${platform}] xcodebuild -scheme ${SCHEME} -destination $(platform_destination "${platform}")"
  if ! xcodebuild \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "$(platform_destination "${platform}")" \
    -derivedDataPath ".build/xcode-${platform}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >"${log_file}" 2>&1; then
    echo "    [${platform}] build FAILED (log: ${log_file#"${ROOT_DIR}/"})"
    grep -E ': (fatal )?error:|\*\* BUILD FAILED \*\*' "${log_file}" | sed -E "s#${ROOT_DIR}/##g" | awk '!seen[$0]++' | head -n 20 | sed 's/^/      /'
    return 1
  fi
}

check_platform() {
  local platform="$1"
  local sdk products_dir probe_dir
  sdk="$(platform_sdk "${platform}")"
  products_dir="${ROOT_DIR}/.build/xcode-${platform}/Build/Products/$(platform_products_dir "${platform}")"
  probe_dir="${WORK_DIR}/${platform}"

  if [[ ${build} -eq 1 ]]; then
    build_package "${platform}" || return 1
  fi

  local objects=()
  while IFS= read -r -d '' object; do
    objects+=("${object}")
  done < <(find "${products_dir}" -maxdepth 1 -name '*.o' -print0 2>/dev/null)
  if [[ ${#objects[@]} -eq 0 ]]; then
    echo "    [${platform}] no object files under ${products_dir#"${ROOT_DIR}/"}; build first or drop --no-build"
    return 1
  fi

  rm -rf "${probe_dir}"
  mkdir -p "${probe_dir}"

  local status=0
  local triple
  for triple in $(platform_triples "${platform}"); do
    local probe="${probe_dir}/OpenClawLinkProbe-${triple}.dylib"
    local link_log="${probe_dir}/link-${triple}.log"
    # -profile-generate links the LLVM profile runtime, which the objects need when the scheme
    # builds with code coverage enabled; it does not affect framework load commands.
    if ! xcrun --sdk "${sdk}" swiftc \
      -target "${triple}" \
      -emit-library \
      -profile-generate \
      -module-name OpenClawLinkProbe \
      -o "${probe}" \
      "${objects[@]}" >"${link_log}" 2>&1; then
      echo "    [${platform}/${triple}] probe link FAILED (log: ${link_log#"${ROOT_DIR}/"})"
      grep -E 'error|Undefined' "${link_log}" | head -n 20 | sed 's/^/      /'
      status=1
      continue
    fi

    local commands weak="" unlinked="" strong=""
    commands="$(load_commands "${probe}")"
    local framework
    for framework in $(watched_frameworks "${platform}"); do
      local line
      # macOS frameworks use versioned install names (Foo.framework/Versions/A/Foo).
      line="$(printf '%s\n' "${commands}" | grep -E "/${framework}\.framework/(Versions/[^/]+/)?${framework}\$" || true)"
      if [[ -z "${line}" ]]; then
        unlinked="${unlinked:+${unlinked} }${framework}"
      elif [[ "${line}" == LC_LOAD_WEAK_DYLIB* ]]; then
        weak="${weak:+${weak} }${framework}"
      else
        strong="${strong:+${strong} }${framework}"
        echo "    [${platform}/${triple}] ${framework}: STRONG (${line%% *}); every reference must be availability-gated"
        nm -m "${probe}" \
          | grep -E "\(undefined\) external .*\(from ${framework}\)" \
          | sed -E 's/^[[:space:]]*\(undefined\) external //; s/ \(from [^)]*\)$//' \
          | demangle \
          | head -n 20 \
          | sed 's/^/        strong ref: /'
        status=1
      fi
    done
    echo "    [${platform}/${triple}] weak: ${weak:-none}; not linked: ${unlinked:-none}; strong: ${strong:-none}"
  done

  if [[ ${status} -eq 0 ]]; then
    echo "    [${platform}] OK"
  else
    echo "    [${platform}] FAILED"
  fi
  return "${status}"
}

mkdir -p "${LOG_DIR}" "${WORK_DIR}"

failed=""
for platform in "${platforms[@]}"; do
  if ! check_platform "${platform}"; then
    failed="${failed:+${failed} }${platform}"
  fi
done

echo
if [[ -n "${failed}" ]]; then
  echo "Weak-link check failed for: ${failed}"
  exit 1
fi
echo "Weak-link check passed for: ${platforms[*]}"
