# Teleprompter: notes on screen, invisible to the recording — design

Date: 2026-11-24
Status: approved 2026-11-24

## Intent

Reuven records course videos, YouTube videos, and ads with ScreenFlow. He wants
notes in front of him while talking, but anything on the recorded screen ends up
in the recording, so today the notes sit off to the side and he's often looking
away from the camera in the final video.

The app puts a small window of notes on the recorded screen, just under the
camera. He can read it; ScreenFlow doesn't capture it. His eyes stay near the
lens.

It will be released as open source.

## Feasibility (verified)

A throwaway spike (2026-11-24, macOS 26.5 Tahoe, current ScreenFlow) showed
that an AppKit window with `NSWindow.sharingType = .none` is absent from
ScreenFlow recordings, and appears when switched to `.readOnly`.

Caveat: public reports (Tauri #14200, Electron #48258) say ScreenCaptureKit
ignores `.none` on macOS 15+, and Apple's docs call it legacy. It works with
ScreenFlow today, empirically; a macOS (e.g. 27) or ScreenFlow update could
change that. Hence the built-in capture check below.

## Goals

- A notes window that ScreenFlow does not record, positioned under the camera.
- Short notes — bullet points, a few headings — that fit on one screen. No
  scrolling or paging needed during a recording.
- Two ways to get notes in: type directly into the app, or open an existing
  Markdown file. He doesn't yet know which he'll prefer; both must be first-class.
- Never interfere with the app being demonstrated (no focus stealing, no
  intercepted clicks) while recording.
- A quick way to re-verify the hiding still works after OS/ScreenFlow updates.

## Non-goals

- A scrolling teleprompter: no auto-scroll, speed control, voice tracking, or
  paging through a script.
- Multiple note sets shown at once, sync, cloud, iOS.
- Mac App Store distribution.
- Workarounds for capture tools that ignore `sharingType` (e.g. relying on
  ScreenFlow app exclusion). Revisit only if an update breaks hiding.

## Anti-goals (failure even if it technically works)

- Notes appearing in a recording without him having explicitly asked for that.
  The app must always launch hidden-from-capture; the "visible" test state is
  never persisted.
- Stealing keyboard focus or clicks from the demo app mid-recording.
- A heavy app (Electron-scale memory, slow launch) for what is a sticky note.

## Approaches considered

1. **Native Swift / AppKit — chosen.** `sharingType` is a native property and
   is exactly what the spike verified. Clean `.app`, small footprint, first-class
   support for non-activating panels, click-through, global hotkeys, and
   floating above full-screen apps. Cost: Swift rather than Python, so the code
   stays small and well commented.
2. **Python + PyObjC.** Would be in Reuven's language and fits the existing `uv`
   scaffold, but packaging a double-clickable `.app` (py2app) is fragile,
   especially on Python 3.15, and the code would be AppKit-in-Python anyway.
   Rejected.
3. **Electron / Tauri.** Same underlying flag via `setContentProtection`, far
   heavier. Rejected without detailed discussion.

Reuven chose Swift. The initial Python `uv` scaffold was removed.

## The design

### Overall shape

- A menu-bar app (status item; no Dock icon — *my call*, so it doesn't clutter
  the Dock or the app switcher during demos).
- One notes window.
- Minimum macOS: 26 (Tahoe), the version where hiding is verified — *my call*.

### The notes window

- Borderless, rounded, dark translucent panel with light text; stays above
  normal windows and full-screen apps, on all Spaces.
- `sharingType = .none` at all times except during an explicit capture check.
- Default position on first launch: top center of the display with the camera
  (the built-in display if present, else the main display), just below the menu
  bar / notch. After that, position, size, and display are remembered.

### Two modes

**Edit mode**
- Normal interactive window: can take focus, can be moved (drag anywhere on
  the background) and resized.
- Shows the raw Markdown in a plain text editor (monospaced or system font,
  builder's choice) so he can type or paste.
- Raw text is shown at a fixed, comfortable size and scrolls; it is never
  shrunk-to-fit while typing (Reuven's decision, 2026-11-24).

**Recording mode**
- Shows the Markdown rendered: headings, bullets (including nesting), numbered
  lists, bold, italic, inline code, paragraphs.
- Click-through (`ignoresMouseEvents`) and never becomes key or main; never
  activates the app.
- Text is not editable.
- Re-fits from the maximum font size whenever the text or window size changes,
  so text grows back as well as shrinks. When the open file changes on disk,
  the view reloads and re-fits immediately, even while recording (Reuven's
  decision, 2026-11-24).

**Switching:** one global keyboard shortcut that works from any app, plus a
menu-bar item. Default shortcut *my call*: ⌃⌥⌘N (chosen to avoid common app
shortcuts). Implemented with Carbon `RegisterEventHotKey`, which needs no
Accessibility permission. Configurable shortcut is out of scope for v1.

The app launches in recording mode if notes exist, edit mode if empty —
*my call*.

### Where notes come from

- **Scratch notes (default):** typed into the app; autosaved to Application
  Support and restored on launch.
- **Markdown file:** "Open…" from the menu bar loads a `.md` file. The app
  watches the file and reloads when it changes on disk, including editors that
  save by atomic replace (write temp + rename), so the watcher must survive the
  file being replaced.
- *My call:* when a file is open, edits made in the app's edit mode are saved
  back to that file (debounced). External changes reload the view. If both
  change at once, the last write wins — acceptable for one user.
- "Close File" returns to scratch notes (scratch content is kept, not
  overwritten by the file).
- Recent files: last few in the menu — *my call*, small and useful.

### When notes don't fit (Reuven's decision)

Recording mode shrinks the text to fit the window. The font-size setting is the
*maximum* size; the renderer steps down until the whole note fits. Below a
minimum readable size (builder's call, roughly 14 pt), it stops shrinking and
shows a clear "more below" marker rather than silently clipping. The fitting
logic lives in `TeleprompterCore` with tests. The window never grows on its own.

### Appearance controls

- Font size: larger/smaller via menu items and ⌘+ / ⌘− while in edit mode.
- Window opacity: a few presets in the menu.
- All persisted in `UserDefaults`.

### Capture check

- Menu item "Show in recordings (test)" switches `sharingType` to `.readOnly`.
- While visible, the window shows an unmistakable indicator (e.g. a red border
  and "VISIBLE TO RECORDING" label) so it can't be left on by accident.
- Not persisted: every launch starts hidden. Also reverts to hidden on the next
  mode switch — *my call*.

## Code structure and quality

This is shipping code (an application with users once open-sourced).

- Swift Package Manager project — *my call*: buildable and testable from the
  command line (`swift build`, `swift test`), no checked-in `.xcodeproj`.
  - `TeleprompterCore` library: Markdown → `NSAttributedString` rendering,
    settings model, file loading/saving/watching, window-placement math, mode
    state machine. Pure, testable logic lives here.
  - `Teleprompter` executable: thin AppKit layer (app delegate, panel, status
    item, hotkey).
  - A `scripts/build-app.sh` that assembles a signed-ad-hoc `.app` bundle
    (Info.plist with `LSUIElement`) from the release build.
- Markdown parsing via Apple's `swift-markdown` (Apache-2.0).
- Tests: Swift Testing, test-first. **100% line coverage gate on
  `TeleprompterCore`**, enforced by a script that reads
  `swift test --enable-code-coverage` output. The AppKit layer is excluded
  from the gate and kept deliberately thin; it gets a written manual
  verification checklist (including a real ScreenFlow recording) run before
  each release — *my call*, since there's no practical way to unit-test
  ScreenFlow capture or global hotkeys.
- Mutation testing: Swift has no `mutmut`; try Muter on `TeleprompterCore`
  before releases if it works with Swift 6.3, otherwise skip and note it —
  *my call*.
- `swift format` / `swift-format lint` in place of ruff.
- Respect the machine-wide test-slot limit (`~/.local/bin/testslot`).
- License: MIT (Reuven's decision).

## Release and distribution (Reuven's decisions)

- Public GitHub repo `teleprompter` from the start.
- Binaries are ad-hoc signed, not notarized. The README explains building from
  source and approving the app once in System Settings › Privacy & Security.
  Developer ID signing + notarization is a possible later task, not v1.

## Settled during review (*my calls*)

- First build milestone after the bare panel: re-verify hiding in a real
  ScreenFlow recording with the actual window setup (non-activating panel, high
  window level, full-screen auxiliary). The spike only tested a plain window.
- Leaving edit mode returns keyboard focus to the previously active app.
- The last opened file is reopened on launch if it still exists; otherwise fall
  back to scratch notes.
- If the global hotkey can't be registered, say so in the menu and keep the
  menu-bar toggle working.
- If the remembered display is gone, fall back to the default position.
- Markdown elements not listed (tables, images, links) render as plain text.

## Left to the builder

- Exact visual styling (corner radius, padding, default font and size).
- Text-editor font in edit mode.
- How the file watcher is implemented, as long as it survives atomic saves.
- Menu layout and wording.
