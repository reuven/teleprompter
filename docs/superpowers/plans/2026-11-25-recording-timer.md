# Recording Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A count-up timer in the notes panel, started/stopped/restarted with ⌃⌥⌘T, with an optional target from the menu that turns the time amber and then red.

**Architecture:** The timer's state machine, display text, color level and the panel's strip geometry are pure values in `TeleprompterCore` (100% coverage, property tests). The app layer adds a label to `NotesContentView`, menu entries through `MenuModel`, and wiring in `AppDelegate` (a second `HotKey`, a refresh timer). No new window.

**Tech Stack:** Swift 6.2 (strict concurrency), AppKit, Swift Testing, `swift-property-based`, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-25-recording-timer-design.md`

## Global Constraints

- macOS 26+, Swift 6 language mode, zero warnings; `swift format lint --strict -r Sources Tests` clean.
- TDD: each test is seen failing for the right reason before the code that passes it. A test filter must report a nonzero test count (`Test run with N tests`, N > 0).
- `scripts/coverage.sh` exits 0 (every `TeleprompterCore` file and every gated app file at 100%). `RecordingTimer.swift` is core, so it's gated automatically.
- Tests run only through `~/.local/bin/testslot`; at most three runs at once machine-wide.
- The notes panel's `sharingType` is set once in `init` and never written again; nothing in this plan touches it. No new windows.
- Shortcut: ⌃⌥⌘T = `kVK_ANSI_T` with `controlKey | optionKey | cmdKey` (physical key, like ⌃⌥⌘N).
- Target presets, in seconds: `[15, 30, 45, 60, 90, 120, 180]`, plus Off (`nil`). Warning lead: 5 seconds.
- Display: `m:ss` under an hour, `h:mm:ss` from an hour; with a target, `"<elapsed> / <target>"`.
- Colors: normal `.white`, warning `.systemOrange`, over `.systemRed`.
- US English in all user-facing text and comments.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; work on branch `feature/recording-timer`, merged into main by the controller.

## Review Focus

1. **The menu open while ⌃⌥⌘T is pressed:** the press must count once. Menu items carry no ⌃⌥⌘T key equivalent (the global hotkey alone handles it), so the press can't fire twice.
2. **Sleep/wake and clock changes:** elapsed time comes from `ContinuousClock`, so it never goes backward; a test feeds instants directly.
3. **The strip and fitting:** in recording mode the notes fit into the height above the strip; showing/hiding the strip refits, and the "more below" badge sits above the strip, not under it.
4. **Exactly at the thresholds:** at `target − 5 s` the level becomes warning, at `target` it becomes over (the display then shows e.g. `1:00 / 1:00` in red).
5. **Edit mode:** the strip shows there too, and typing in the editor is unaffected.

---

### Task 1: Timer core (state, display, levels) and the target setting

**Files:**
- Create: `Sources/TeleprompterCore/RecordingTimer.swift`
- Modify: `Sources/TeleprompterCore/Settings.swift` (new `timerTarget`)
- Test: `Tests/TeleprompterCoreTests/RecordingTimerTests.swift` (create), `Tests/TeleprompterCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces:
  - `public struct RecordingTimer: Equatable, Sendable` with
    `public enum Phase: Equatable, Sendable { case hidden; case running(since: ContinuousClock.Instant); case stopped(elapsed: Duration) }`,
    `public private(set) var phase: Phase` (starts `.hidden`),
    `public mutating func press(at now: ContinuousClock.Instant)` (hidden → running(now); running → stopped(now − since); stopped → running(now)),
    `public mutating func hide()` (any → hidden),
    `public func elapsed(at now: ContinuousClock.Instant) -> Duration` (hidden: `.zero`; never negative),
    `public var isVisible: Bool` (phase ≠ hidden), `public var isRunning: Bool`.
  - `public enum TimerLevel: Equatable, Sendable { case normal, warning, over }`
  - `public enum TimerDisplay` with `public static let warningLead = 5`,
    `public static func format(seconds: Int) -> String`,
    `public static func text(elapsed: Duration, target: Int?) -> String`,
    `public static func level(elapsed: Duration, target: Int?) -> TimerLevel`.
    Both `text` and `level` use whole elapsed seconds (rounded down), so the color changes when the shown number does.
  - `public enum TimerStrip` with `public static let height: CGFloat = 30` and
    `public static func notesFrame(in bounds: CGRect, showsTimer: Bool) -> CGRect` (bounds minus a bottom strip of `height` when showing, clamped to non-negative height; AppKit's y-up coordinates, so the notes frame starts at `minY + height`).
  - `Settings.timerTarget: Int?` (seconds), `Settings.timerTargetPresets: [Int]`; any stored value not in the presets normalizes to `nil`, on both `init` and decoding (missing key → `nil`).

- [ ] **Step 1: Write the failing tests** in `RecordingTimerTests.swift`:

```swift
@Test func pressCyclesStartStopRestart() {
    let t0 = ContinuousClock.now
    var timer = RecordingTimer()
    #expect(timer.phase == .hidden && !timer.isVisible)
    timer.press(at: t0)
    #expect(timer.phase == .running(since: t0) && timer.isRunning)
    timer.press(at: t0 + .seconds(47))
    #expect(timer.phase == .stopped(elapsed: .seconds(47)))
    #expect(timer.elapsed(at: t0 + .seconds(500)) == .seconds(47))  // frozen
    timer.press(at: t0 + .seconds(600))
    #expect(timer.phase == .running(since: t0 + .seconds(600)))
    #expect(timer.elapsed(at: t0 + .seconds(601)) == .seconds(1))
}
@Test func hideResets() { /* press, hide → .hidden, elapsed == .zero, next press starts at 0 */ }
@Test func elapsedNeverNegative() { /* running since t0, elapsed(at: t0 - .seconds(3)) == .zero */ }
@Test func formats() {
    #expect(TimerDisplay.format(seconds: 0) == "0:00")
    #expect(TimerDisplay.format(seconds: 42) == "0:42")
    #expect(TimerDisplay.format(seconds: 600) == "10:00")
    #expect(TimerDisplay.format(seconds: 3723) == "1:02:03")
    #expect(TimerDisplay.text(elapsed: .milliseconds(42_900), target: nil) == "0:42")
    #expect(TimerDisplay.text(elapsed: .seconds(42), target: 60) == "0:42 / 1:00")
}
@Test func levelsAtTheBoundaries() {
    #expect(TimerDisplay.level(elapsed: .seconds(54), target: 60) == .normal)
    #expect(TimerDisplay.level(elapsed: .milliseconds(54_999), target: 60) == .normal)
    #expect(TimerDisplay.level(elapsed: .seconds(55), target: 60) == .warning)
    #expect(TimerDisplay.level(elapsed: .milliseconds(59_999), target: 60) == .warning)
    #expect(TimerDisplay.level(elapsed: .seconds(60), target: 60) == .over)
    #expect(TimerDisplay.level(elapsed: .seconds(9_999), target: nil) == .normal)
}
@Test func stripTakesTheBottom() {
    let b = CGRect(x: 0, y: 0, width: 400, height: 200)
    #expect(TimerStrip.notesFrame(in: b, showsTimer: false) == b)
    #expect(TimerStrip.notesFrame(in: b, showsTimer: true) == CGRect(x: 0, y: 30, width: 400, height: 170))
    #expect(TimerStrip.notesFrame(in: CGRect(x: 0, y: 0, width: 400, height: 10), showsTimer: true).size.height == 0)
}
```

  Properties (with `propertyCheck`): for any seconds in `0...360_000`, `format` round-trips (split on `:`, recombine to the same seconds) and has two-digit minutes/seconds fields after the first; for any target preset and elapsed `e1 <= e2`, `level(e1)` ≤ `level(e2)` in the order normal < warning < over (monotonic).

  In `SettingsTests.swift`: `timerTarget` defaults to nil; a preset round-trips through encode/decode; `45` survives, `44`, `-1` and `Int.max` normalize to nil; JSON without the key decodes to nil.

- [ ] **Step 2: Run and watch them fail.** `~/.local/bin/testslot -- swift test --filter 'RecordingTimerTests|SettingsTests'` → compile failure (types missing).
- [ ] **Step 3: Implement** `RecordingTimer.swift` and the `Settings` field to the interfaces above. `level` compares whole seconds `s` with `target`: `s >= target` → over, `s >= target - warningLead` → warning.
- [ ] **Step 4: Run and watch them pass** (same command, nonzero count). Break `>=` to `>` in `level` once and see `levelsAtTheBoundaries` fail; revert.
- [ ] **Step 5: Commit** `RecordingTimer: count-up timer state, display text and levels; Settings.timerTarget`.

### Task 2: The timer strip in the notes view

**Files:**
- Modify: `Sources/Teleprompter/NotesContentView.swift`
- Test: `Tests/TeleprompterTests/NotesContentViewTests.swift`

**Interfaces:**
- Consumes: `TimerStrip.notesFrame(in:showsTimer:)`, `TimerLevel`.
- Produces: `let timerLabel: NSTextField` (monospaced-digit system font, 18 pt, semibold, right-aligned, hidden by default) and `func showTimer(_ text: String?, level: TimerLevel)` — nil hides the strip; otherwise shows `text` in `.white` / `.systemOrange` / `.systemRed`. Showing or hiding re-lays out the reader and the editor's scroll view into `TimerStrip.notesFrame(in: bounds, showsTimer:)` (also on every resize) and refits in recording mode. The "more below" badge is pinned to the reader's bottom edge, so it sits above the strip.

- [ ] **Step 1: Failing tests** (in the existing `.guiSession` suite): the label is hidden by default and the reader fills the bounds; `showTimer("0:42", level: .normal)` shows the label with that text and white, and the reader's frame equals `TimerStrip.notesFrame(in: bounds, showsTimer: true)`; `.warning` → `.systemOrange`, `.over` → `.systemRed`; `showTimer(nil, …)` hides it and restores the full frame; in recording mode with long notes, `fittedFontSize` with the strip is ≤ the size without it and the badge's frame `minY` ≥ the strip height; in edit mode the editor's scroll view takes the notes frame too.
- [ ] **Step 2: Run, see them fail** (`--filter NotesContentViewTests`, nonzero count).
- [ ] **Step 3: Implement.** Replace the reader's and scroll view's autoresizing with frames set in `layout()`/`setFrameSize` from `TimerStrip.notesFrame`; keep `drawableSize` reading the reader's bounds so fitting uses the smaller area.
- [ ] **Step 4: Run, see them pass;** run the whole `NotesContentViewTests` and `NotesPanelTests`.
- [ ] **Step 5: Commit** `NotesContentView: timer strip below the notes`.

### Task 3: Timer menu entries

**Files:**
- Modify: `Sources/Teleprompter/MenuModel.swift`
- Test: `Tests/TeleprompterTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `RecordingTimer.Phase`, `Settings.timerTarget`, `Settings.timerTargetPresets`, `TimerDisplay.format(seconds:)`.
- Produces: `MenuAction` cases `.timerPress`, `.hideTimer`, `.timerTarget(Int?)`. `MenuModel.init` gains `timerPhase: RecordingTimer.Phase` and `timerShortcutUnavailable: Bool` (after `shortcutUnavailable`). A new group, after the text/opacity group and before "Show in Recordings (Test)": `"Start Timer"` / `"Stop Timer"` / `"Restart Timer"` (hidden / running / stopped) → `.timerPress`; `"Hide Timer"` → `.hideTimer`, present only while the phase isn't hidden; info line `"Shortcut ⌃⌥⌘T unavailable"` when flagged; submenu `"Timer Target"` with `"Off"` then each preset formatted (`"0:15"` … `"3:00"`), the current one checked. No item has a key equivalent.

- [ ] **Step 1: Failing tests:** titles of the timer group for each phase (exact title list for the default model updated); Hide Timer absent while hidden; the info line only when flagged; target submenu titles `["Off", "0:15", "0:30", "0:45", "1:00", "1:30", "2:00", "3:00"]` with exactly the current one checked (Off by default); each item's action; no timer item has a `keyEquivalent`.
- [ ] **Step 2: Run, see them fail.** **Step 3: Implement.** **Step 4: Run, see them pass** (nonzero count; also run any test constructing `MenuModel`).
- [ ] **Step 5: Commit** `MenuModel: timer start/stop/restart, hide and target`.

### Task 4: Wiring, docs and GUI checks

**Files:**
- Modify: `Sources/Teleprompter/AppDelegate.swift`, `README.md`, `docs/manual-checklist.md`, `scripts/gui-checks.sh`, `TODO.md`

**Interfaces:**
- Consumes: everything above; `HotKey(keyCode:modifiers:handler:)`.

- [ ] **Step 1:** In `AppDelegate`: a `RecordingTimer`; a second `HotKey` for ⌃⌥⌘T calling `pressTimer()` (nil → `timerShortcutUnavailable = true`); `pressTimer()` / `hideTimer()` / `setTimerTarget(_:)` update state, save the target in settings, refresh the menu and the label. While running, a `Timer` (0.25 s, added to the run loop in `.common` modes so it ticks while a menu is open) updates the label through `showTimer(TimerDisplay.text(…), level: TimerDisplay.level(…))`; it's invalidated when the timer stops or hides. Elapsed comes from `ContinuousClock.now`. Handle the three new `MenuAction`s.
- [ ] **Step 2:** `scripts/build-app.sh`, then extend `scripts/gui-checks.sh` (Accessibility clicks only): Start Timer → a static text matching `^0:0[0-9]$` appears in the panel; after ~2 s it has advanced; Stop Timer → the text stays the same across 1.5 s; Timer Target › 0:15 → the text ends in `/ 0:15`; Hide Timer → the text is gone; and the window server still reports the panel hidden from capture (sharing state 0) with the strip showing. Run it; all checks pass.
- [ ] **Step 3:** README usage: ⌃⌥⌘T and the target menu. Manual checklist: in section 1 (ScreenFlow), the timer strip is absent from the recording while running; a new item for the colors (amber in the last 5 seconds, red past the target). TODO: the timer.
- [ ] **Step 4:** `scripts/coverage.sh` exits 0; `swift format lint --strict -r Sources Tests` clean; no warnings.
- [ ] **Step 5: Commit** `Recording timer: ⌃⌥⌘T, menu, docs and GUI checks`.
