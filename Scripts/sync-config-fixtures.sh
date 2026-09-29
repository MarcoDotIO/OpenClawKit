#!/usr/bin/env bash
# Re-copies the upstream config contract fixtures used by the config document tests.
#
# Usage: Scripts/sync-config-fixtures.sh [--check] [--allow-missing-upstream] [upstream-checkout]
#   upstream-checkout defaults to $OPENCLAW_UPSTREAM_DIR or .codex/openclaw.
#   --check                   sync into a scratch directory and fail if Tests/Fixtures/Config differs
#   --allow-missing-upstream  exit 0 with a warning when the upstream checkout is absent (CI)
#
# Copies test/fixtures/config-corpus/*.json, test/fixtures/doctor-2026.7.1.json and
# test/fixtures/talk-config-contract.json, and extracts every ```json5 block from the gateway
# configuration docs into Tests/Fixtures/Config/docs/<doc>-<n>.json5. Run it during a parity sync and
# review the diff: new or changed fixtures are expected to decode without typeMismatch issues.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/Tests/Fixtures/Config"

check=0
allow_missing=0
upstream_arg=""
for arg in "$@"; do
    case "${arg}" in
        --check) check=1 ;;
        --allow-missing-upstream) allow_missing=1 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) upstream_arg="${arg}" ;;
    esac
done
UPSTREAM_DIR="${upstream_arg:-${OPENCLAW_UPSTREAM_DIR:-${ROOT_DIR}/.codex/openclaw}}"

if [[ ! -d "${UPSTREAM_DIR}/test/fixtures" ]]; then
    if [[ ${allow_missing} -eq 1 ]]; then
        echo "warning: upstream checkout not found at ${UPSTREAM_DIR}; skipping config fixture check." >&2
        exit 0
    fi
    echo "Upstream checkout not found at ${UPSTREAM_DIR} (pass it as the first argument)." >&2
    exit 1
fi

if [[ ${check} -eq 1 ]]; then
    DEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-config-fixtures.XXXXXX")"
    trap 'rm -rf "${DEST_DIR}"' EXIT
else
    DEST_DIR="${FIXTURES_DIR}"
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

if [[ ${check} -eq 1 ]]; then
    status=0
    # The recorded commit is an abbreviated SHA whose length depends on the git version; compare it
    # as a prefix of the checkout's full HEAD instead of byte-for-byte.
    recorded_commit="$(tr -d '[:space:]' <"${FIXTURES_DIR}/UPSTREAM_COMMIT" 2>/dev/null || true)"
    full_commit="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [[ -z "${recorded_commit}" || "${full_commit}" != "${recorded_commit}"* ]]; then
        echo "Config fixtures were synced from ${recorded_commit:-<none>}, but ${UPSTREAM_DIR} is at ${full_commit}." >&2
        status=1
    fi
    if ! diff -r -x UPSTREAM_COMMIT "${FIXTURES_DIR}" "${DEST_DIR}" >/dev/null; then
        echo "Config fixtures drifted from ${UPSTREAM_DIR} (${upstream_commit}):" >&2
        diff -rq -x UPSTREAM_COMMIT "${FIXTURES_DIR}" "${DEST_DIR}" \
            | sed -E "s#${DEST_DIR}#<upstream>#g; s#${ROOT_DIR}/##g" | head -n 40 >&2
        status=1
    fi
    if [[ ${status} -ne 0 ]]; then
        echo "Run Scripts/sync-config-fixtures.sh and review the diff." >&2
        exit 1
    fi
    echo "Config fixtures match ${UPSTREAM_DIR} (${upstream_commit})."
    exit 0
fi
echo "Synced config fixtures from ${UPSTREAM_DIR} (${upstream_commit}) into ${DEST_DIR}."
