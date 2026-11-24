#!/usr/bin/env bash
# Fails unless every file under Sources/TeleprompterCore/, plus the app files that decide whether
# notes stay out of recordings (NotesPanel.swift, CaptureTestWindow.swift, CaptureCheck.swift),
# has 100% line coverage.
set -euo pipefail
cd "$(dirname "$0")/.."

~/.local/bin/testslot -- swift test --enable-code-coverage
json="$(swift test --show-codecov-path)"

# Prints "<file> <percent>" for each gated file; -1 when the percent is missing.
gate() {
  jq -r --arg match "$1" '
    .data[0].files[]
    | select(.filename | contains($match))
    | "\(.filename | split("/") | last) \(.summary.lines.percent // -1)"
  ' "$json"
}

# Checks one report: non-empty, every percent numeric and at least 100.
check() {
  local label="$1" report="$2"
  if [ -z "$report" ]; then
    echo "No $label files found in coverage report" >&2
    exit 1
  fi
  echo "$report"
  echo "$report" | awk '$2 !~ /^-?[0-9.]+$/ || $2 + 0 < 100 { bad = 1 } END { exit bad }' || {
    echo "Coverage below 100% in $label" >&2
    exit 1
  }
}

check TeleprompterCore "$(gate /Sources/TeleprompterCore/)"
check NotesPanel.swift "$(gate /Sources/Teleprompter/NotesPanel.swift)"
check CaptureTestWindow.swift "$(gate /Sources/Teleprompter/CaptureTestWindow.swift)"
check CaptureCheck.swift "$(gate /Sources/Teleprompter/CaptureCheck.swift)"
