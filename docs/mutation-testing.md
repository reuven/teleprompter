# Mutation testing

Two complementary checks on `Sources/TeleprompterCore`: an automated Muter run (`scripts/mutation.sh`) and, for the file Muter cannot handle, a manual spot-check.

Tools: Muter 16 (`brew install muter-mutation-testing/formulae/muter`), Swift 6.3, Xcode 26.6, macOS 26.5. Run on 2026-11-24.

## Muter result

**92% of 50 mutants killed (46/50), measured at commit a82fb18 (Core source unchanged by the later release-docs commits). This is not a whole-library score.** It covers 6 of 7 Core files and 3 of 4 Muter operators (RelationalOperatorReplacement, RemoveSideEffects, ChangeLogicalConnector). It excludes `MarkdownRenderer.swift` (Muter crashes the unmutated baseline on it; see the manual spot-check below) and every SwapTernary mutant (Muter emits uncompilable code). The denominator grew from 35 to 50 because Task 10 changed `NotesStore` and `Settings` (26 and 4 mutants now), so the earlier 82% is not comparable to this run.

Every row below is a Muter measurement (`scripts/mutation.sh`), labeled with the commit it ran at.

| Measured at | Mutants | Killed | Score |
|---|---|---|---|
| 582e925 (main, before any new tests; Core unchanged since the run) | 35 | 26 | 74% |
| e287a4c's tests (measured just before that commit) | 35 | 27 | 77% |
| 2b13419 (timer tests added; before Task 10) | 35 | 29 | 82% |
| a82fb18 (current: release branch, after Task 10; no new tests needed) | 50 | 46 | 92% |

The 4 survivors in the current run: FileWatcher:117, Placement:61 (twice), TextFitter:51. All four are Muter artifacts or timing-only, and were already checked by hand (below): none reflects an untested behavior, so no new tests were added. NotesStore:206 and NotesStore:260, survivors in the 82% run, were killed in this one (NotesStore is 26/26). Muter counts a crash or compile failure of the mutated build as killed. The run took about 22 minutes (the machine was shared).

## How to re-run

```sh
scripts/mutation.sh
```

It writes a gitignored `muter.conf.yml` for this checkout, runs Muter inside one test slot, and leaves the JSON report at `muter_logs/muter-report.json` (gitignored). It takes 11 to 22 minutes. Do not run other `swift test` commands in this checkout meanwhile: Muter builds in this checkout's `.build`.

## What Muter could not do (exact failures, trimmed)

1. `--files-to-mutate` takes one file per flag; a space-joined list gives `Muter wasn't able to discover on list provided by the files-to-mutate flag.`
2. The copy Muter makes carries a stale module cache: `error: precompiled file '.../_mutated/.build/.../_Builtin_stdbool-....pcm' was compiled with module cache path '.../.build/...'`. Fixed with `--scratch-path` pointing at the original `.build`.
3. SwapTernary drops the space before `?` on the multi-line ternaries `swift format` produces: `TextFitter.swift:69:52: error: cannot use optional chaining on non-optional value of type 'Double'` (instrumented source: `maxFontSize > 0? floor : max(...)`). Left out of `--operators`; no ternary mutants run.
4. Muter runs the test command with an empty environment: `error: command Applying debug entitlements to .../debug/Teleprompter failed: unable to spawn process 'codesign' (No such file or directory)`. Fixed with `executable: /usr/bin/env` and a `PATH=` argument.
5. With `MarkdownRenderer.swift` included the unmutated baseline crashes: `*** Terminating app due to uncaught exception 'NSRangeException', reason: 'NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds'`. Muter's instrumentation of `visitParagraph` (an if/else that starts with a comment) leaves the original branch as a bare `return`, so paragraphs render nothing. Same with only two operators. Not fixable without editing production code or Muter.
6. Mutants nested inside another mutated function or closure are never inserted (the instrumented source has no switch for them, checked in the copy), yet Muter reports them as "passed": FileWatcher:117, NotesStore:260, Placement:61 (two), TextFitter:51. These five "survivors" are artifacts, so the real score is better than reported. They were checked by hand instead (below).

## Survivors killed

Each was verified by hand-mutating the source, running the named test through `testslot`, and restoring the file.

| Mutant | Killed by |
|---|---|
| NotesStore:138 `userEdited` drops `pendingTask?.cancel()` | `eachEditRestartsTheDebounce` (2 s delay, edits at 0 and 1 s, check at 2.5 s) |
| NotesStore:158 `savePendingNow` drops `pendingTask?.cancel()` | `flushCancelsTheTimerOfTheEditItSaved`: a stale timer saves the next edit early |
| NotesStore:187 `cancelPendingSave` drops `pendingTask?.cancel()` | `externalChangeCancelsTheTimerOfTheEditItDropped`: same, after an external change |
| TextFitter:51 `<=` to `<` | `heightExactlyEqualToBoxFits` |

## Checked by hand, already killed by existing tests

| Mutant | Killed by |
|---|---|
| NotesStore:260 `pending == nil` to `!= nil` | `deletedFileIsNeverRecreated`, `deletedOpenFileFallsBack` |
| Placement:61 `>=` to `>` | `exactlyHalfOnScreenIsKept`, `halfOnEachScreenIsNotSummed` |
| Placement:61 `>=` to `<` | `exactlyHalfOnScreenIsKept`, `keepsSavedFrameOnConnectedScreen` |
| Placement:61 `&&` to `\|\|` | `dropsMostlyOffscreenFrame` |

## Survivors left, and why

| Mutant | Reason |
|---|---|
| NotesStore:206 `switchToScratch` drops `watcher?.stop()` | Equivalent (and not reported as a survivor in the a82fb18 run). Checked: the whole NotesStore suite passes. The next line sets `watcher = nil`; nothing else retains the `FileWatcher` (its callback captures `self` weakly), so `FileWatcher.deinit` stops the watch at once. |
| FileWatcher:117 `retriesLeft > 0` to `>= 0` | One extra 50 ms retry before giving up; observable only by timing, and a test would be flaky. Not inserted by Muter either. |
| MarkdownRenderer `max(0, indent - 1.2 * fontSize)` clamp removed | Equivalent: outdent is only used at depth 1 or deeper, where the value is never negative. |

## Manual mutation spot-check (MarkdownRenderer)

Muter cannot run on this file, so each mutation below was applied by hand, one at a time, to `MarkdownRenderer.swift`; `swift test --filter MarkdownRendererTests` was run through `testslot`, and the file was restored afterward. The ternary Muter choked on is `outdent ? max(0, indent - 1.2 * fontSize) : indent` (swapped below). 42 mutations: 32 killed by the existing tests, 10 survived; 9 of those are now killed by six new tests and 1 is equivalent.

| Mutation | Original tests | After new tests |
|---|---|---|
| Heading: h1 scale 1.4 -> 1.2 | killed by headingsScale, scalesWithFontSize | |
| Heading: h2 scale 1.2 -> 1.4 | killed by headingsScale | |
| Heading: default scale (h3+) 1.1 -> 1.2 | killed by headingsScale | |
| Heading: headingScale not reset to 1 | **survived** | now killed by bodyTextAfterAHeadingIsPlain (new test) |
| Heading: bold not inserted | killed by headingsScale, inlineCodeKeepsBoldInHeadingAndStrong | |
| Heading: bold not removed after heading | **survived** | now killed by bodyTextAfterAHeadingIsPlain (new test) |
| List: depth + 1 -> + 0 | killed by bulletsAndNesting, onlyBulletLineIsOutdented, scalesWithFontSize | |
| List: listDepth counts nothing (count -> 0) | killed by bulletsAndNesting, scalesWithFontSize | |
| List: indent factor 1.2 -> 1.0 | killed by bulletsAndNesting, scalesWithFontSize | |
| List: ordered index ignores position (startIndex only) | killed by orderedListStartIndex | |
| List: ordered index off by one (+1) | killed by orderedListStartIndex | |
| List: bullet glyph changed to - | killed by bulletsAndNesting, multiParagraphListItem | |
| List: marker not followed by tab | killed by bulletsAndNesting, multiParagraphListItem, orderedListStartIndex | |
| List: outdent: true -> false | killed by onlyBulletLineIsOutdented | |
| List: text after marker keeps outdented style (restyle line removed) | killed by onlyBulletLineIsOutdented | |
| Paragraph: first-in-list index 0 -> 1 | killed by bulletsAndNesting, multiParagraphListItem, orderedListStartIndex | |
| Paragraph: parent is ListItem -> is not ListItem | killed by bulletsAndNesting, multiParagraphListItem, orderedListStartIndex | |
| Paragraph: `,` -> || (any first child or list item child) | killed by multiParagraphListItem | |
| Paragraph: else-branch depth ignores listDepth | **survived** | now killed by laterParagraphInAListItemIsIndentedWithTheItem (new test) |
| Paragraph style: outdent ternary swapped | killed by onlyBulletLineIsOutdented | |
| Paragraph style: outdent amount 1.2 -> 0.6 | **survived** | now killed by bulletHangsOneLevelAndTabsToTheText (new test) |
| Paragraph style: max(0, ...) clamp removed | **survived** | equivalent: `indent - 1.2 * fontSize` is never negative, because outdent is only used at depth 1 or deeper, so `max(0, ...)` never clamps |
| Paragraph style: paragraphSpacing 0.4 -> 0.5 | killed by blocksSeparatedByOneNewlineNoTrailing, scalesWithFontSize | |
| Paragraph style: tab stop location indent -> 0 | **survived** | now killed by bulletHangsOneLevelAndTabsToTheText (new test) |
| Strong: bold not inserted | killed by inlineCodeKeepsBoldInHeadingAndStrong, strongAndEmphasisSeparately, strongEmphasisCombine | |
| Strong: restore condition inverted (if had) | killed by strongAndEmphasisSeparately | |
| Strong: never removes bold afterwards | killed by strongAndEmphasisSeparately | |
| Emphasis: italic not inserted | killed by strongAndEmphasisSeparately, strongEmphasisCombine | |
| Emphasis: restore condition inverted | **survived** | now killed by italicEndsWithTheEmphasisEvenWhenNested (new test) |
| Emphasis: never removes italic afterwards | **survived** | now killed by italicEndsWithTheEmphasisEvenWhenNested (new test) |
| InlineCode: monospaced not set | killed by inlineCodeIsMonospaced, inlineCodeKeepsBoldInHeadingAndStrong | |
| InlineCode: monospaced not reset | **survived** | now killed by monospaceEndsWithTheInlineCode (new test) |
| Font: traits ignored when building font (guard !traits.isEmpty -> always base) | killed by headingsScale, inlineCodeKeepsBoldInHeadingAndStrong, strongAndEmphasisSeparately, strongEmphasisCombine | |
| Font: monospaced ignored | killed by inlineCodeIsMonospaced, inlineCodeKeepsBoldInHeadingAndStrong | |
| startBlock: separator newline dropped | killed by blockquoteAndThematicBreak, blocksSeparatedByOneNewlineNoTrailing, codeBlockShowsPlainText, multiParagraphListItem, orderedListStartIndex | |
| Table: row separator newline dropped | killed by tableCellsTabSeparatedRowsNewline | |
| Table: cell separator tab dropped | killed by tableCellsTabSeparatedRowsNewline | |
| Table: tableRows not reset per table | **survived** | now killed by eachTableStartsItsOwnRows (new test) |
| CodeBlock: trailing newlines not trimmed | killed by codeBlockShowsPlainText | |
| HTMLBlock: trailing newlines not trimmed | killed by htmlShowsPlainText | |
| SoftBreak: space -> newline | killed by softAndHardBreaks | |
| LineBreak: newline -> space | killed by softAndHardBreaks | |
