# Teleprompter

A macOS menu-bar app that puts your notes on the screen you're recording, just
under the camera, without them showing up in the recording. Built for recording
with ScreenFlow, so you can read your notes while looking at the lens instead
of off to the side.

Requires macOS 26 or later. MIT licensed.

## Install

1. Download `Teleprompter-<version>.zip` from the
   [Releases page](https://github.com/reuven/teleprompter/releases) and unzip it. You get a
   `Teleprompter-<version>` folder holding `Teleprompter.app`, `LICENSE`, and
   `THIRD_PARTY_NOTICES.md`.
2. Move `Teleprompter.app` from that folder to `/Applications`.
3. The app is ad-hoc signed, not notarized, so macOS blocks the first open. Open it once,
   then go to System Settings › Privacy & Security, scroll down, and click **Open Anyway**.

Or, from Terminal, remove the quarantine flag before the first open:

```sh
xattr -dr com.apple.quarantine /Applications/Teleprompter.app
```

That flag is the marker macOS puts on downloaded files so Gatekeeper checks them; removing it
tells macOS you trust this app. Only do that for a zip you got from this repo's Releases page.

## Build from source

Requires Xcode 26 (Swift 6.2 or later).

```sh
scripts/build-app.sh
open build/Teleprompter.app
```

This builds a universal (Apple silicon and Intel) app at `build/Teleprompter.app` and signs it
ad hoc.

## Usage

- The app lives in the menu bar (no Dock icon). The notes panel floats under the camera on
  every Space, above full-screen apps.
- **Edit Notes** lets you type; **Lock for Recording** makes the panel click-through and
  stops it taking focus, so your typing and clicks go to the app underneath.
- **⌃⌥⌘N** (the physical N key, so it works with any input source) toggles between the two
  from any app. If another app owns that shortcut, the menu says "Shortcut ⌃⌥⌘N unavailable".
- Notes are Markdown: headings, bold, italic, code, lists, quotes, and tables render in
  recording mode.
- The text shrinks to fit the panel (set the largest size with Larger/Smaller Text, or ⌘+ and
  ⌘− in the panel). When even the smallest size does not fit, a "▼ more below" badge shows.
- Without a file open, notes are saved automatically to
  `~/Library/Application Support/Teleprompter/scratch.md`.
- **Open…** (and Open Recent) shows a `.md`, `.markdown`, or `.txt` file instead. The app
  watches it: edits you make in the panel are saved back, and changes made in another editor
  appear live. Close File returns to your scratch notes.
- Position, size, font size, opacity, and the last file are remembered between launches.

## Is it really hidden? The capture test

The panel sets `NSWindow.sharingType = .none`, which asks macOS to keep it out of screen
capture. Whether a capture app honors that is up to the app.

- **Show in Recordings (Test)** in the menu shows a separate red-bordered test box that
  deliberately *is* visible to capture. Record a few seconds: if the box appears and your
  notes do not, hiding works.
- The app also checks itself: if any of its windows is capturable, the menu shows
  "⚠ Notes may be visible to recordings — quit and relaunch".

**Re-check after every macOS or ScreenFlow update.** This works with ScreenFlow on macOS 26
as tested, but it is empirical, not guaranteed. Apps built on ScreenCaptureKit have been
reported to ignore `sharingType = .none` on newer macOS releases (for example
[Tauri #14200](https://github.com/tauri-apps/tauri/issues/14200) and
[Electron #48258](https://github.com/electron/electron/issues/48258)), and ScreenFlow could
change how it captures. Run the capture test, and do the ScreenFlow section of
[`docs/manual-checklist.md`](docs/manual-checklist.md), before an important recording.

## Privacy

No network access, no telemetry, no accounts. Your notes stay on your Mac, in the scratch file
or the file you opened.

## Development

```sh
swift test                 # run the tests
scripts/coverage.sh        # tests plus the 100% line-coverage gate on the gated files
scripts/mutation.sh        # Muter mutation testing on TeleprompterCore (about 20 minutes)
swift format lint --strict -r Sources Tests
```

- `scripts/coverage.sh` and `scripts/mutation.sh` run the tests through `testslot`, the
  author's local tool that limits how many test runs happen at once. If
  `~/.local/bin/testslot` is not installed they print a note and run directly, so you don't
  need it.
- Mutation results, scope, and how to re-run: [`docs/mutation-testing.md`](docs/mutation-testing.md).
- Before a release, run [`docs/manual-checklist.md`](docs/manual-checklist.md); it covers what
  tests cannot (ScreenFlow, focus, second displays).
- Design: [`docs/superpowers/specs/2026-11-24-teleprompter-design.md`](docs/superpowers/specs/2026-11-24-teleprompter-design.md).

## Acknowledgments

Markdown is parsed with [swift-markdown](https://github.com/swiftlang/swift-markdown) (Apache
License 2.0) and [swift-cmark](https://github.com/swiftlang/swift-cmark), Apple's fork of
cmark-gfm (BSD-2-Clause and others). Their license texts are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), which also ships inside the app and in the
release zip.

## License

MIT, see [LICENSE](LICENSE).
