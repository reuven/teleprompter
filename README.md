# Teleprompter

A macOS menu-bar app that puts your notes on the screen you're recording, just
under the camera, without them showing up in the recording. Built for recording
with ScreenFlow, so you can read your notes while looking at the lens instead
of off to the side.

**Status:** in development. See the design in
[`docs/superpowers/specs/2026-11-24-teleprompter-design.md`](docs/superpowers/specs/2026-11-24-teleprompter-design.md).

## How it works

The notes window sets `NSWindow.sharingType = .none`, which asks macOS to keep
the window out of screen captures. This has been verified with ScreenFlow on
macOS 26 (Tahoe). Capture apps decide for themselves whether to honor it, so
re-check after macOS or ScreenFlow updates; the app has a built-in test switch
for exactly that.

## Requirements

- macOS 26 or later
- Xcode 26 / Swift 6.3 to build from source

## License

MIT — see [LICENSE](LICENSE).
