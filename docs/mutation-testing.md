# Mutation testing (Muter)

Tool: Muter 16 (`brew install muter-mutation-testing/formulae/muter`), Swift 6.3, Xcode 26.6, macOS 26.5.
Run on 2026-11-24 against `Sources/TeleprompterCore`. Config: `muter.conf.yml` (committed).

## Result

| | Mutants | Killed | Score |
|---|---|---|---|
| Before new tests | 35 | 26 | 74% |
| After new tests | 35 | 27 | 77% |

This covers six of the seven core files, with three of Muter's four operators. See "What Muter could not do".
Muter counts a crash or compile failure of the mutated build as killed.

## How to re-run

Muter hard-codes the project path in the config (`--scratch-path`); edit `muter.conf.yml` if the checkout moves.
Do not use a `.build` directory created in another location (Muter copies the project to `../<name>_mutated` and a stale module cache breaks the build).

```sh
A=(); for f in Sources/TeleprompterCore/*.swift; do [[ $f == *MarkdownRenderer* ]] || A+=(--files-to-mutate $f); done
~/.local/bin/testslot -- muter run --skip-update-check -f json -o muter-report.json \
  --operators RelationalOperatorReplacement --operators RemoveSideEffects \
  --operators ChangeLogicalConnector $A
```

The whole run takes about 7 minutes and holds one test slot. The JSON report is written inside the copy
(`../<name>_mutated/muter-report.json`). `muter_logs/` is gitignored.

## What Muter could not do (exact failures, trimmed)

1. Default `--files-to-mutate $FILES` with a space-joined string: `Muter wasn't able to discover on list provided by the files-to-mutate flag.`
   The flag must be repeated once per file.
2. Copied `.build` has a stale module cache:
   `error: precompiled file '.../teleprompter-impl_mutated/.build/.../_Builtin_stdbool-....pcm' was compiled with module cache path '.../teleprompter-impl/.build/...'`
   Fixed with `--scratch-path <abs path to original .build>` in the config.
3. All operators: Muter's SwapTernary rewrite drops the space before `?` on the multi-line ternaries that `swift format` produces, so the
   instrumented code does not compile:
   `TextFitter.swift:69:52: error: cannot use optional chaining on non-optional value of type 'Double'` (source: `maxFontSize > 0? floor : max(...)`),
   and the same at `MarkdownRenderer.swift:89`. Worked around by leaving SwapTernary out of `--operators`. No ternary mutants were run.
4. Muter runs the test command with an empty environment: `error: command Applying debug entitlements to .../debug/Teleprompter failed: unable to spawn process 'codesign' (No such file or directory)`.
   Worked around with `executable: /usr/bin/env` and a `PATH=...` argument.
5. `MarkdownRenderer.swift` cannot be mutated. With it included, the unmutated baseline run crashes:
   `*** Terminating app due to uncaught exception 'NSRangeException', reason: 'NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds'`
   because Muter's instrumentation of `visitParagraph` (an if/else whose first line is a comment) leaves the original `else` branch as an empty `return`,
   so paragraphs render nothing. Same crash with only RelationalOperatorReplacement + ChangeLogicalConnector. Fixing it means editing production code
   or patching Muter, so MarkdownRenderer (30 of the original 65 mutants) is **not covered by any mutation score here**.
6. Mutants nested inside another mutated function or closure (FileWatcher 117, NotesStore 260, Placement 61 x2, TextFitter 51) are never inserted:
   the instrumented source has no switch for them (checked in the copy). Muter still reports them as "passed", so those 5 "survivors" are artifacts
   and the true score is slightly better than reported. The two that matter were checked by hand (below).

## Survivors killed

| Mutant | Test |
|---|---|
| NotesStore.swift:138, remove `pendingTask?.cancel()` in `userEdited` (debounce no longer restarts) | `NotesStoreTests.eachEditRestartsTheDebounce`. Verified by hand: fails with the line removed. |
| TextFitter.swift:51, `<=` to `<` (not inserted by Muter; mutated by hand) | `TextFitterTests.heightExactlyEqualToBoxFits`. Verified by hand: fails with `<`. |

## Survivors left, and why

| Mutant | Reason |
|---|---|
| NotesStore.swift:158, remove `pendingTask?.cancel()` in `savePendingNow` | Equivalent: a stale timer later finds `pending == nil` and does nothing. |
| NotesStore.swift:187, remove `pendingTask?.cancel()` in `cancelPendingSave` | Equivalent: same reason; `userEdited` cancels before scheduling anew. |
| NotesStore.swift:206, remove `watcher?.stop()` in `switchToScratch` | Equivalent: the next line sets `watcher = nil`, and `FileWatcher.deinit` stops it. |
| NotesStore.swift:260, `pending == nil` to `!=` | Not actually inserted by Muter; already covered by `deletedFileIsNeverRecreated` and `deletedOpenFileFallsBack` (both check the "discarded" wording). |
| FileWatcher.swift:117, `retriesLeft > 0` to `>= 0` | Not inserted by Muter. Would add one extra 50 ms retry; only timing-observable, not worth a flaky test. |
| Placement.swift:61, `&&` to `\|\|` | Not inserted by Muter. Equivalent anyway: `CGRect.null` has zero size, so the area test also fails. |
| Placement.swift:61, `>=` to other | Not inserted by Muter; the boundary is pinned by `exactlyHalfOnScreenIsKept`. |
