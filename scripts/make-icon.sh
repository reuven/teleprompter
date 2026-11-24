#!/usr/bin/env bash
# Regenerates scripts/AppIcon.icns (the app icon) and the blog/README PNGs in docs/images from
# their SVG sources. Run it after editing an SVG; the outputs are committed so a normal build
# doesn't need this step.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swiftc -O scripts/render-svg.swift -o "$tmp/render-svg"

# An .iconset holds each size at 1x and 2x; iconutil packs it into one .icns.
iconset="$tmp/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    "$tmp/render-svg" docs/images/teleprompter-appicon.svg "$iconset/icon_${size}x${size}.png" "$size"
    "$tmp/render-svg" docs/images/teleprompter-appicon.svg "$iconset/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$iconset" -o scripts/AppIcon.icns

for name in icon glyph; do
    for px in 1024 2048; do
        "$tmp/render-svg" "docs/images/teleprompter-$name.svg" "docs/images/teleprompter-$name-$px.png" "$px"
    done
done
echo "Wrote scripts/AppIcon.icns and docs/images/*.png"
