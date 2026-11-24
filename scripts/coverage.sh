#!/usr/bin/env bash
# Fails unless every file under Sources/TeleprompterCore/ has 100% line coverage.
set -euo pipefail
cd "$(dirname "$0")/.."

~/.local/bin/testslot -- swift test --enable-code-coverage
json="$(swift test --show-codecov-path)"

report="$(jq -r '
  .data[0].files[]
  | select(.filename | contains("/Sources/TeleprompterCore/"))
  | "\(.filename | split("/") | last) \(.summary.lines.percent)"
' "$json")"

if [ -z "$report" ]; then
  echo "No TeleprompterCore files found in coverage report" >&2
  exit 1
fi

echo "$report"
echo "$report" | awk '$2 < 100 { bad = 1 } END { exit bad }' || {
  echo "Coverage below 100% in TeleprompterCore" >&2
  exit 1
}
