#!/usr/bin/env bash
# Verifies that Apple frameworks which do not exist at the package's minimum deployment
# targets (iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 26) are only weak-linked.
#
# Usage: Scripts/check-apple-weak-links.sh [ios|tvos|watchos|visionos|macos|all] [--no-build]
#        (default platform: ios)
#        Scripts/check-apple-weak-links.sh <platform> --binary <Mach-O>
#        (checks an already linked app or framework binary, e.g. MyApp.app/MyApp, instead of
#        building the package probe)
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
#   4. Symbol-level check: fails when the probe has a strong (non-weak) undefined reference to a
#      Swift runtime symbol that only exists in the 27 runtimes. Framework-level checks cannot
#      see these, because libswift_Concurrency and friends are always loaded. Example: the
#      Swift 6.4 compiler inlines `withTaskCancellationShield` into strong references to
#      `swift_task_cancellationShieldPush`/`Pop`, even behind `#available`; iOS 26.x does not
#      export them, so an app at the iOS 17 floor would fail to launch before iOS 27.
#
# A framework is weak-linked only when EVERY symbol referenced from it is availability-gated
# (`@available`/`#available` with a version newer than the deployment target). Frameworks that
# are not linked at all pass.
#
# Watched frameworks (defaults):
#   - 27-only, every platform: CoreAI StateReporting NowPlaying MediaIntelligence
#     MusicUnderstanding SuggestedActions TrustInsights LinkSecurity
#   - newer than the iOS 17 / macOS 14 / tvOS 17 / watchOS 10 floors but already present at the
#     visionOS 26 floor, so exempt on visionOS: FoundationModels, TelephonyMessagingKit (iOS 26),
#     ImagePlayground (iOS 18.1 / macOS 15.1), ManagedApp (iOS 18.4 / macOS 27)
#   A framework a platform does not ship at all is reported as "not linked" there.
#
# Environment:
#   OPENCLAW_WEAK_LINK_FRAMEWORKS  space-separated framework names to watch (overrides defaults)
#   OPENCLAW_STRONG_SYMBOL_DENYLIST
#                                  space-separated extended regexes of runtime symbols that must
#                                  never be strongly referenced (overrides the default list)
#   OPENCLAW_SCHEME                scheme to build (default: OpenClawKit-Package)
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Relative --binary paths are resolved against the caller's directory, before the cd below.
CALLER_DIR="$(pwd)"
cd "${ROOT_DIR}"

SCHEME="${OPENCLAW_SCHEME:-OpenClawKit-Package}"
WORK_DIR="${ROOT_DIR}/.build/weak-link-probe"
LOG_DIR="${ROOT_DIR}/.build/logs"

# Frameworks introduced after the package floors. The 27 list is new in the 27 SDKs on every
# platform. The floor list holds frameworks newer than the iOS 17 / macOS 14 floors that already
# exist at the visionOS 26 floor (FoundationModels and TelephonyMessagingKit ship with the 26
# SDKs, ImagePlayground with iOS 18.1 / macOS 15.1, ManagedApp with iOS 18.4 / macOS 27), so
# they may be strong on visionOS.
DEFAULT_27_FRAMEWORKS="CoreAI StateReporting NowPlaying MediaIntelligence MusicUnderstanding SuggestedActions TrustInsights LinkSecurity"
DEFAULT_FLOOR_FRAMEWORKS="FoundationModels TelephonyMessagingKit ImagePlayground ManagedApp"

# Swift runtime symbols that only exist in the 27 runtimes (extended regexes matched against the
# C symbol name as `nm` prints it). A strong reference to any of them breaks launch before 27.
DEFAULT_STRONG_SYMBOL_DENYLIST="^_swift_task_cancellationShieldPush$ ^_swift_task_cancellationShieldPop$ cancellationShield"

usage() {
  echo "Usage: $(basename "$0") [ios|tvos|watchos|visionos|macos|all] [--no-build]" >&2
  echo "       $(basename "$0") <ios|tvos|watchos|visionos|macos> --binary <Mach-O>" >&2
  echo "       (--binary inspects an already linked app/framework binary instead of building)" >&2
}

requested="ios"
build=1
binary=""
expect_binary=0
for arg in "$@"; do
  if [[ ${expect_binary} -eq 1 ]]; then
    binary="${arg}"
    expect_binary=0
    continue
  fi
  case "${arg}" in
    --no-build) build=0 ;;
    --binary) expect_binary=1 ;;
    -h|--help) usage; exit 0 ;;
    ios|tvos|watchos|visionos|macos|all) requested="${arg}" ;;
    *) usage; exit 2 ;;
  esac
done
if [[ ${expect_binary} -eq 1 ]]; then
  usage
  exit 2
fi

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
    # The floor frameworks already exist at the visionOS 26 floor, so they may be strong there.
    visionos) echo "${DEFAULT_27_FRAMEWORKS}" ;;
    *) echo "${DEFAULT_FLOOR_FRAMEWORKS} ${DEFAULT_27_FRAMEWORKS}" ;;
  esac
}

strong_symbol_denylist() {
  echo "${OPENCLAW_STRONG_SYMBOL_DENYLIST:-${DEFAULT_STRONG_SYMBOL_DENYLIST}}"
}

# Prints "<symbol> (from <library>)" for every strong (non-weak) undefined symbol of a binary that
# matches the denylist. `nm -m` prints weak imports as "(undefined) weak external".
denied_strong_symbols() {
  local binary="$1" pattern regex=""
  for pattern in $(strong_symbol_denylist); do
    regex="${regex:+${regex}|}(${pattern})"
  done
  [[ -z "${regex}" ]] && return 0
  nm -m "${binary}" \
    | awk '/\(undefined\)/ && !/\(undefined\) (\[lazy bound\] )?weak external / {
        if (match($0, /external [^ ]+/)) {
          sym = substr($0, RSTART + 9, RLENGTH - 9)
          lib = $0
          sub(/.*\(from /, "", lib)
          sub(/\)$/, "", lib)
          print sym, lib
        }
      }' \
    | awk -v regex="${regex}" '$1 ~ regex { print $1 " (from " $2 ")" }'
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

# Checks one linked Mach-O image: watched frameworks must not be strong load commands, and no
# denylisted 27-only runtime symbol may be strongly referenced.
# Usage: inspect_binary <platform> <label> <binary>
inspect_binary() {
  local platform="$1" label="$2" binary="$3" status=0
  local commands weak="" unlinked="" strong=""
  commands="$(load_commands "${binary}")"
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
      echo "    [${label}] ${framework}: STRONG (${line%% *}); every reference must be availability-gated"
      nm -m "${binary}" \
        | grep -E "\(undefined\) external .*\(from ${framework}\)" \
        | sed -E 's/^[[:space:]]*\(undefined\) external //; s/ \(from [^)]*\)$//' \
        | demangle \
        | head -n 20 \
        | sed 's/^/        strong ref: /'
      status=1
    fi
  done
  echo "    [${label}] weak: ${weak:-none}; not linked: ${unlinked:-none}; strong: ${strong:-none}"

  local denied
  denied="$(denied_strong_symbols "${binary}")"
  if [[ -n "${denied}" ]]; then
    echo "    [${label}] STRONG references to 27-only runtime symbols (launch fails before 27):"
    printf '%s\n' "${denied}" | sed 's/^/        strong ref: /'
    status=1
  else
    echo "    [${label}] runtime symbols: no strong references to 27-only symbols ($(strong_symbol_denylist | wc -w | tr -d ' ') patterns)"
  fi
  return "${status}"
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

    inspect_binary "${platform}" "${platform}/${triple}" "${probe}" || status=1
  done

  if [[ ${status} -eq 0 ]]; then
    echo "    [${platform}] OK"
  else
    echo "    [${platform}] FAILED"
  fi
  return "${status}"
}

if [[ -n "${binary}" ]]; then
  if [[ "${requested}" == "all" ]]; then
    echo "--binary needs one platform (its watched-framework list), not 'all'" >&2
    exit 2
  fi
  if [[ "${binary}" != /* ]]; then
    binary="${CALLER_DIR}/${binary}"
  fi
  if [[ ! -f "${binary}" ]]; then
    echo "No such binary: ${binary}" >&2
    exit 2
  fi
  echo "==> [${requested}] inspecting ${binary}"
  if inspect_binary "${requested}" "${requested}/$(basename "${binary}")" "${binary}"; then
    echo
    echo "Weak-link check passed for: ${binary}"
    exit 0
  fi
  echo
  echo "Weak-link check failed for: ${binary}"
  exit 1
fi

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
