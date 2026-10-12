#!/bin/bash
# Builds emvnc.app from emvnc.xcodeproj with xcodebuild (needs Xcode): Release, universal (arm64 + x86_64).
# Usage: [VERSION=1.2.0] [BUILD_NUMBER=42] scripts/build-xcode.sh   → build/Release/emvnc.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/build/DerivedData"
OUTPUT="$ROOT/build/Release"

settings=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
if [[ -n "${VERSION:-}" ]]; then settings+=(MARKETING_VERSION="$VERSION"); fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then settings+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER"); fi

xcodebuild -project "$ROOT/emvnc.xcodeproj" -scheme emvnc -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" \
    "${settings[@]}" build

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
ditto "$DERIVED_DATA/Build/Products/Release/emvnc.app" "$OUTPUT/emvnc.app"

echo "Built $OUTPUT/emvnc.app"
