#!/usr/bin/env bash
# Runs Muter mutation testing on Sources/TeleprompterCore (see docs/mutation-testing.md).
# Generates muter.conf.yml (gitignored) with this checkout's paths, then runs Muter inside one
# test slot. Takes about 20 minutes. The JSON report lands in muter_logs/muter-report.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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

# Muter runs the test command with an empty environment, so `env` supplies PATH (codesign is
# needed to link the app target). --scratch-path points at the original .build because the
# copy Muter makes would otherwise carry a module cache pointing at the wrong directory.
cat > muter.conf.yml <<YAML
arguments:
- PATH=$PATH
- /usr/bin/swift
- test
- --scratch-path
- $ROOT/.build
executable: /usr/bin/env
exclude:
- Package.swift
- Tests
- Sources/Teleprompter/
excludeCalls: []
YAML

# MarkdownRenderer.swift is skipped: Muter's instrumentation breaks `visitParagraph`, so the
# unmutated baseline run crashes. SwapTernary is left out: it emits uncompilable code.
files=()
for f in Sources/TeleprompterCore/*.swift; do
  [[ "$f" == *MarkdownRenderer.swift ]] || files+=(--files-to-mutate "$f")
done

# Muter copies the project to a sibling directory named <name>_mutated and a leftover one
# from an earlier run could be stale, so start each run from a fresh copy. Only that exact
# sibling path (guarded by basename) is deleted.
rm -rf "$ROOT/../$(basename "$ROOT")_mutated"
mkdir -p muter_logs
slot muter run --skip-update-check -f json -o muter_logs/muter-report.json \
  --operators RelationalOperatorReplacement --operators RemoveSideEffects \
  --operators ChangeLogicalConnector "${files[@]}"

# Muter writes the report inside its copy of the project; bring it back.
cp "$ROOT/../$(basename "$ROOT")_mutated/muter_logs/muter-report.json" muter_logs/muter-report.json
