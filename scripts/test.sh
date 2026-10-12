#!/bin/bash
# Runs the unit tests of the emvnc fork of RoyalVNCKit and of EmVNCKit.
# The Command Line Tools sometimes omit the Swift Testing macro plugin on incremental builds; pass it explicitly
# there. Xcode finds it on its own.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_FLAGS=()

plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$plugin" ]]; then
    PLUGIN_FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$plugin")
fi

swift test --package-path "$ROOT/Packages/RoyalVNCKit" ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"}
swift test --package-path "$ROOT/Packages/EmVNCKit" ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"}
