#!/usr/bin/env bash
# Runs every generator and fixture drift check against the pinned upstream OpenClaw checkout
# (v2026.9.6, eb377ac59e). Each check regenerates its output in memory and fails when the committed
# file differs, so a parity refresh cannot silently drift.
#
# Usage: Scripts/check-upstream-drift.sh [--allow-missing-upstream]
#
#   --allow-missing-upstream  skip (with a warning) instead of failing when the upstream checkout
#                             is absent. CI uses this: the checkout is not part of the repository.
#
# Environment:
#   OPENCLAW_UPSTREAM_DIR  upstream OpenClaw git checkout (default: <repo>/.codex/openclaw)
#
# Checks (all read-only):
#   node Scripts/protocol-gen-swift.mjs --check                 OpenClawProtocol vendored models + method catalog
#   node Scripts/provider-catalog-gen.mjs --check               OpenClawModels ProviderCatalogData.swift
#   node Scripts/channel-catalog-gen.mjs --check                OpenClawChannels generated channel catalog
#   node Scripts/check-native-state-parity.mjs                  OpenClawNativeState schema version + DDL
#   node Scripts/sync-upstream-gateway-method-fixtures.mjs --check
#   node Scripts/sync-upstream-runtime-ext-fixtures.mjs --check
#   node Scripts/sync-upstream-tool-catalog-fixture.mjs --check
#   Scripts/sync-config-fixtures.sh --check                     Tests/Fixtures/Config corpus
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

allow_missing=0
for arg in "$@"; do
  case "${arg}" in
    --allow-missing-upstream) allow_missing=1 ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "Usage: $(basename "$0") [--allow-missing-upstream]" >&2
      exit 2
      ;;
  esac
done

if ! command -v node >/dev/null 2>&1; then
  echo "node is required for the generator drift checks." >&2
  exit 1
fi

export OPENCLAW_UPSTREAM_DIR="${OPENCLAW_UPSTREAM_DIR:-${ROOT_DIR}/.codex/openclaw}"
upstream_present=0
if [[ -e "${OPENCLAW_UPSTREAM_DIR}/.git" ]]; then
  upstream_present=1
fi

if [[ ${upstream_present} -eq 0 ]]; then
  if [[ ${allow_missing} -eq 0 ]]; then
    echo "Upstream OpenClaw checkout not found at ${OPENCLAW_UPSTREAM_DIR} (set OPENCLAW_UPSTREAM_DIR)." >&2
    exit 1
  fi
  echo "warning: upstream OpenClaw checkout not found at ${OPENCLAW_UPSTREAM_DIR}; drift checks are skipped."
fi

missing_flag=()
if [[ ${allow_missing} -eq 1 ]]; then
  missing_flag=(--allow-missing-upstream)
fi

# Plain strings instead of arrays: macOS ships bash 3.2, where expanding an empty array under
# `set -u` is an error.
failed=""
passed=""
skipped=""
passed_count=0

run_check() {
  local label="$1"
  shift
  echo "==> ${label}"
  if "$@"; then
    passed="${passed:+${passed}, }${label}"
    passed_count=$((passed_count + 1))
  else
    failed="${failed:+${failed}, }${label}"
  fi
}

run_check "protocol models" node Scripts/protocol-gen-swift.mjs --check ${missing_flag[@]+"${missing_flag[@]}"}
run_check "provider catalog" node Scripts/provider-catalog-gen.mjs --check ${missing_flag[@]+"${missing_flag[@]}"}
run_check "channel catalog" node Scripts/channel-catalog-gen.mjs --check ${missing_flag[@]+"${missing_flag[@]}"}
# Exits 0 ("skipped") on its own when the upstream revision is unreachable.
run_check "native state schema" node Scripts/check-native-state-parity.mjs
run_check "gateway method fixtures" node Scripts/sync-upstream-gateway-method-fixtures.mjs --check ${missing_flag[@]+"${missing_flag[@]}"}
run_check "runtime extension fixtures" node Scripts/sync-upstream-runtime-ext-fixtures.mjs --check ${missing_flag[@]+"${missing_flag[@]}"}
if [[ ${upstream_present} -eq 1 ]]; then
  # This generator reads the upstream working tree directly and has no missing-upstream mode.
  run_check "tool catalog fixture" node Scripts/sync-upstream-tool-catalog-fixture.mjs --check
else
  skipped="tool catalog fixture"
fi
run_check "config fixtures" Scripts/sync-config-fixtures.sh --check ${missing_flag[@]+"${missing_flag[@]}"}

echo
if [[ ${upstream_present} -eq 1 ]]; then
  echo "Passed: ${passed_count}${passed:+ (${passed})}"
else
  echo "Exited cleanly without the upstream checkout (nothing was compared): ${passed_count}${passed:+ (${passed})}"
fi
if [[ -n "${skipped}" ]]; then
  echo "Skipped (no upstream checkout): ${skipped}"
fi
if [[ -n "${failed}" ]]; then
  echo "FAILED: ${failed}"
  exit 1
fi
if [[ ${upstream_present} -eq 1 ]]; then
  echo "Upstream drift checks passed."
else
  echo "Upstream drift checks skipped: no upstream checkout."
fi
