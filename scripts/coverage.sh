#!/usr/bin/env bash
# Fails unless every file under Sources/TeleprompterCore/, plus the app files that decide whether
# notes stay out of recordings (NotesPanel.swift, CaptureTestWindow.swift, CaptureCheck.swift),
# plus the notes view, the global shortcut and the capture shield (NotesContentView.swift,
# HotKey.swift, CaptureShield.swift), plus every menu decision, the Open… filter, the quit
# check, the frame saver and the focus rule after modals (MenuModel.swift,
# NotesFileChooser.swift, QuitDecision.swift, FrameSaver.swift, FocusReturn.swift), has 100%
# line coverage. AppDelegate, StatusMenu
# and main.swift are thin AppKit glue, checked by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

# testslot is the author's local limiter (at most three concurrent test runs on one machine).
# Without it, run the command directly.
slot() {
  if [ -x "$HOME/.local/bin/testslot" ]; then
    "$HOME/.local/bin/testslot" -- "$@"
  else
    echo "note: ~/.local/bin/testslot not found; running directly" >&2
    "$@"
  fi
}

slot swift test --enable-code-coverage

# Since Swift 6.4, SwiftPM builds one test bundle per test target, and the summary at
# --show-codecov-path is exported from only one of them, so the app's files went missing.
# Export the report from the merged profile and every test bundle instead. (A missing file
# still fails below: the gate requires each gated file to be present, not just not low.)
profdata="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
binaries=()
for bundle in "$(swift build --show-bin-path)"/*.xctest; do
  [ -d "$bundle" ] && binaries+=("$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
if [ ${#binaries[@]} -eq 0 ]; then
  echo "No test bundles found next to the build products" >&2
  exit 1
fi
objects=()
for binary in "${binaries[@]:1}"; do objects+=(-object "$binary"); done
json="$(mktemp)"
trap 'rm -f "$json"' EXIT
xcrun llvm-cov export -summary-only -instr-profile "$profdata" "${binaries[0]}" \
  ${objects[@]+"${objects[@]}"} >"$json"

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
check NotesContentView.swift "$(gate /Sources/Teleprompter/NotesContentView.swift)"
check HotKey.swift "$(gate /Sources/Teleprompter/HotKey.swift)"
check CaptureShield.swift "$(gate /Sources/Teleprompter/CaptureShield.swift)"
check MenuModel.swift "$(gate /Sources/Teleprompter/MenuModel.swift)"
check NotesFileChooser.swift "$(gate /Sources/Teleprompter/NotesFileChooser.swift)"
check QuitDecision.swift "$(gate /Sources/Teleprompter/QuitDecision.swift)"
check FrameSaver.swift "$(gate /Sources/Teleprompter/FrameSaver.swift)"
check FocusReturn.swift "$(gate /Sources/Teleprompter/FocusReturn.swift)"
