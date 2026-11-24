#!/usr/bin/env bash
# Builds the release zip for VERSION and prints its SHA-256 and the `gh release create` command
# (printed, never run: publishing is a deliberate manual step).
# Usage: scripts/release.sh 0.1.0 [--dry-run]
# Refuses unless on main, clean, with tag vVERSION at HEAD. --dry-run skips only the tag check.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: scripts/release.sh VERSION [--dry-run]}"
dry_run=0
[ "${2:-}" = "--dry-run" ] && dry_run=1

[ "$(git branch --show-current)" = "main" ] || [ "$dry_run" = 1 ] || { echo "Not on main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean" >&2; exit 1; }
if [ "$dry_run" = 0 ]; then
  git tag --points-at HEAD | grep -qx "v$version" || { echo "No tag v$version at HEAD" >&2; exit 1; }
else
  echo "(dry run: tag check skipped; branch check relaxed)"
fi

rm -rf dist
mkdir dist
scripts/build-app.sh
zip="dist/Teleprompter-$version.zip"
ditto -c -k --keepParent build/Teleprompter.app "$zip"

echo "SHA-256:"
shasum -a 256 "$zip"
echo
echo "Not run. When ready, publish with:"
echo "  gh release create v$version $zip --title \"Teleprompter $version\" --notes-file <notes>"
