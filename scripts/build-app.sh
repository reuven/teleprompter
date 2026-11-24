#!/usr/bin/env bash
# Builds build/Teleprompter.app: a release binary in a minimal bundle, ad-hoc signed.
# Why a script instead of Xcode: the project is a plain SwiftPM package, and a menu-bar app only
# needs Info.plist (LSUIElement hides the Dock icon) plus a signature to launch cleanly.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/Teleprompter"

version="$(git describe --tags --always)"
app="build/Teleprompter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/Teleprompter"
cp scripts/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"

codesign --force --sign - "$app"
echo "Built $app ($version)"
