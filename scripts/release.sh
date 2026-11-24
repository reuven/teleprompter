#!/usr/bin/env bash
# Runs the coverage gate, then builds the release zip for VERSION and prints its SHA-256 and the
# `gh release create` command (printed, never run: publishing is a deliberate manual step).
# The zip holds one folder, Teleprompter-VERSION/, with Teleprompter.app, LICENSE and
# THIRD_PARTY_NOTICES.md (the licenses of the statically linked libraries must ship with it).
# Usage: scripts/release.sh VERSION [--dry-run]   (VERSION as N.N.N; --dry-run in any position)
# Refuses unless on main, tree clean, with tag vVERSION at HEAD, in a full (non-shallow) clone.
# --dry-run skips the branch and tag checks (a clean tree is still required) and does not print
# the gh command.
set -euo pipefail
cd "$(dirname "$0")/.."

version=""
dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *)
      [ -z "$version" ] || { echo "Only one VERSION allowed" >&2; exit 2; }
      version="$arg"
      ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "usage: scripts/release.sh VERSION [--dry-run]  (VERSION like 0.1.0)" >&2
  exit 2
}

[ "$(git rev-parse --is-shallow-repository)" = "false" ] || { echo "Shallow clone" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean" >&2; exit 1; }
if [ "$dry_run" = 0 ]; then
  [ "$(git branch --show-current)" = "main" ] || { echo "Not on main" >&2; exit 1; }
  git tag --points-at HEAD | grep -qx "v$version" || { echo "No tag v$version at HEAD" >&2; exit 1; }
else
  echo "DRY RUN: branch and tag checks skipped"
fi

# The full test suite and the 100% coverage gate, on exactly this tree, in dry runs too. Run as its
# own command so `set -e` stops the release on its exit status (no pipe or && chain to hide it).
scripts/coverage.sh

rm -rf dist
mkdir dist
VERSION="$version" scripts/build-app.sh

app="build/Teleprompter.app"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[ "$built" = "$version" ] || { echo "Built version $built != $version" >&2; exit 1; }
archs="$(lipo -archs "$app/Contents/MacOS/Teleprompter")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || {
  echo "Binary is not universal (archs: $archs)" >&2
  exit 1
}

[ -f "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ] || {
  echo "App bundle is missing THIRD_PARTY_NOTICES.md" >&2
  exit 1
}

# Stage the folder the user will see after unzipping, then zip it as one top-level folder.
stage="dist/Teleprompter-$version"
mkdir "$stage"
ditto "$app" "$stage/Teleprompter.app"
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/"
zip="dist/Teleprompter-$version.zip"
# --norsrc leaves out extended attributes (macOS adds com.apple.provenance to built files). Kept,
# they become ._* AppleDouble entries that plain `unzip` extracts into the bundle as extra files,
# which breaks its code signature. The signature itself is in the bundle's files, not in xattrs.
ditto -c -k --norsrc --keepParent "$stage" "$zip"
# Listed into a variable first: `zipinfo | grep -q` could fail under pipefail when grep exits early.
listing="$(zipinfo -1 "$zip")"
for entry in Teleprompter.app/Contents/MacOS/Teleprompter LICENSE THIRD_PARTY_NOTICES.md; do
  grep -qx "Teleprompter-$version/$entry" <<<"$listing" || {
    echo "Zip is missing Teleprompter-$version/$entry" >&2
    exit 1
  }
done
! grep -q '/\._' <<<"$listing" || { echo "Zip contains ._* AppleDouble entries" >&2; exit 1; }

echo "Version $built, archs: $archs"
echo "SHA-256:"
shasum -a 256 "$zip"
echo
if [ "$dry_run" = 1 ]; then
  echo "DRY RUN — do not publish"
else
  echo "Not run. When ready, publish with:"
  echo "  gh release create v$version $zip --title \"Teleprompter $version\" --notes-file <notes>"
fi
