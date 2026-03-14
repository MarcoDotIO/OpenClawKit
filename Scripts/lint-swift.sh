#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${ROOT_DIR}/.swiftlint.yml"

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "swiftlint is required. Install it with Homebrew: brew install swiftlint" >&2
    exit 1
fi

swift_files=()
while IFS= read -r -d '' file; do
    swift_files+=("${file}")
done < <(find "${ROOT_DIR}/Sources" "${ROOT_DIR}/Tests" "${ROOT_DIR}/Examples" -name '*.swift' -print0)
swift_files+=("${ROOT_DIR}/Package.swift")

swiftlint lint \
    --config "${CONFIG_PATH}" \
    --force-exclude \
    --strict \
    "${swift_files[@]}"
