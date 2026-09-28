#!/usr/bin/env bash
# Re-copies the upstream config contract fixtures used by the config document tests.
#
# Usage: Scripts/sync-config-fixtures.sh [upstream-checkout]
#   upstream-checkout defaults to $OPENCLAW_UPSTREAM_DIR or .codex/openclaw.
#
# Copies test/fixtures/config-corpus/*.json, test/fixtures/doctor-2026.7.1.json and
# test/fixtures/talk-config-contract.json, and extracts every ```json5 block from the gateway
# configuration docs into Tests/Fixtures/Config/docs/<doc>-<n>.json5. Run it during a parity sync and
# review the diff: new or changed fixtures are expected to decode without typeMismatch issues.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="${1:-${OPENCLAW_UPSTREAM_DIR:-${ROOT_DIR}/.codex/openclaw}}"
DEST_DIR="${ROOT_DIR}/Tests/Fixtures/Config"

if [[ ! -d "${UPSTREAM_DIR}/test/fixtures" ]]; then
    echo "Upstream checkout not found at ${UPSTREAM_DIR} (pass it as the first argument)." >&2
    exit 1
fi

mkdir -p "${DEST_DIR}/corpus" "${DEST_DIR}/docs"
rm -f "${DEST_DIR}/corpus/"*.json "${DEST_DIR}/docs/"*.json5

cp "${UPSTREAM_DIR}/test/fixtures/config-corpus/"*.json "${DEST_DIR}/corpus/"
cp "${UPSTREAM_DIR}/test/fixtures/doctor-2026.7.1.json" "${DEST_DIR}/doctor-2026.7.1.json"
cp "${UPSTREAM_DIR}/test/fixtures/talk-config-contract.json" "${DEST_DIR}/talk-config-contract.json"

for doc in configuration-examples config-secrets-env config-runtime config-gateway config-automation; do
    source_file="${UPSTREAM_DIR}/docs/gateway/${doc}.md"
    [[ -f "${source_file}" ]] || continue
    awk -v dest="${DEST_DIR}/docs" -v doc="${doc}" '
        /^[[:space:]]*```json5[[:space:]]*$/ { inside = 1; count += 1; file = sprintf("%s/%s-%02d.json5", dest, doc, count); next }
        /^[[:space:]]*```/ { if (inside) { inside = 0; close(file) }; next }
        inside { print > file }
    ' "${source_file}"
done

upstream_commit="$(git -C "${UPSTREAM_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "${upstream_commit}" > "${DEST_DIR}/UPSTREAM_COMMIT"
echo "Synced config fixtures from ${UPSTREAM_DIR} (${upstream_commit}) into ${DEST_DIR}."
