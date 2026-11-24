#!/usr/bin/env bash
# Builds build/Teleprompter.app: a release binary in a minimal bundle, ad-hoc signed.
# Why a script instead of Xcode: the project is a plain SwiftPM package, and a menu-bar app only
# needs Info.plist (LSUIElement hides the Dock icon) plus a signature to launch cleanly.
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal binary (Apple silicon + Intel); with more than one --arch SwiftPM builds through
# xcbuild, so the products path comes from --show-bin-path with the same flags.
archs=(--arch arm64 --arch x86_64)
swift build -c release "${archs[@]}"
bin="$(swift build -c release "${archs[@]}" --show-bin-path)/Teleprompter"

# CFBundleShortVersionString: the tag without its "v" and without any -N-gSHA suffix
# (v0.1.0-3-gabc123 -> 0.1.0); "0.1.0" when there is no tag. CFBundleVersion must be numeric:
# the commit count.
described="$(git describe --tags --abbrev=0 2>/dev/null || true)"
version="${described#v}"
version="${version:-0.1.0}"
build="$(git rev-list --count HEAD)"
app="build/Teleprompter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/Teleprompter"
cp scripts/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build" "$app/Contents/Info.plist"

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app ($version, build $build)"
