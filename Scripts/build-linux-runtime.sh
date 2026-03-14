#!/usr/bin/env bash
set -euo pipefail

swift build \
  --target OpenClawProtocol \
  --target OpenClawCore \
  --target OpenClawGateway \
  --target OpenClawMedia \
  --target OpenClawMemory \
  --target OpenClawSkills \
  --target OpenClawModels \
  --target OpenClawAgents \
  --target OpenClawPlugins \
  --target OpenClawChannels \
  -Xswiftc -warnings-as-errors
