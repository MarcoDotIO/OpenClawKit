#!/usr/bin/env bash
set -euo pipefail

targets=(
  OpenClawProtocol
  OpenClawCore
  OpenClawGateway
  OpenClawMedia
  OpenClawMemory
  OpenClawSkills
  OpenClawModels
  OpenClawAgents
  OpenClawPlugins
  OpenClawChannels
)

if [[ "$(uname -s)" == "Darwin" ]]; then
  targets+=(
    OpenClawKit
    OpenClawChatUI
  )
fi

args=()
for target in "${targets[@]}"; do
  args+=(--target "$target")
done

swift build \
  "${args[@]}" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
