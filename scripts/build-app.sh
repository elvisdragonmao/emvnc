#!/bin/bash
# Builds emvnc.app with the Swift Package Manager (works with only the Command Line Tools installed).
# Usage: [VERSION=1.2.0] [BUILD_NUMBER=42] scripts/build-app.sh [debug|release]   → build/emvnc.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
PACKAGE="$ROOT/Packages/EmVNCKit"
APP="$ROOT/build/emvnc.app"

BUNDLE_ID="dev.emvnc.emvnc"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DEPLOYMENT_TARGET="14.0"

swift build --package-path "$PACKAGE" -c "$CONFIGURATION" --product emvnc
BIN_DIR="$(swift build --package-path "$PACKAGE" -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/emvnc" "$APP/Contents/MacOS/emvnc"

# Fill in the Xcode build-setting placeholders used by App/Info.plist
sed -e "s/\$(EXECUTABLE_NAME)/emvnc/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$DEPLOYMENT_TARGET/" \
    "$ROOT/App/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

if [[ -f "$ROOT/App/AppIcon.icns" ]]; then
    cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough to run locally. Distribute with a Developer ID signature instead.
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
