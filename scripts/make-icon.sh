#!/bin/bash
# Regenerates App/Assets.xcassets/AppIcon.appiconset and App/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t emvnc-icon)"
MASTER="$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
APPICONSET="$ROOT/App/Assets.xcassets/AppIcon.appiconset"

swift "$ROOT/scripts/make-icon.swift" "$MASTER"

mkdir -p "$ICONSET" "$APPICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    pixels="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/icon_$name.png" >/dev/null
    cp "$ICONSET/icon_$name.png" "$APPICONSET/icon_$name.png"
done

iconutil -c icns "$ICONSET" -o "$ROOT/App/AppIcon.icns"

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$ROOT/App/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Icon written to App/AppIcon.icns and App/Assets.xcassets"
