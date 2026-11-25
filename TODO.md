# TODO — Teleprompter v0.1.0

Task-level checklist. Step-by-step checkboxes, tests and exact values live in the
plan: [`docs/superpowers/plans/2026-11-24-teleprompter.md`](docs/superpowers/plans/2026-11-24-teleprompter.md).
Design: [`docs/superpowers/specs/2026-11-24-teleprompter-design.md`](docs/superpowers/specs/2026-11-24-teleprompter-design.md).

## Setup
- [x] Feasibility spike: `sharingType = .none` hides a window from ScreenFlow (macOS 26.5)
- [x] Design approved; Python scaffold removed; MIT license; public GitHub repo
- [x] Implementation plan written and approved
- [x] Plan amended: property tests, panel-invariant tests, earlier mutation testing

## Implementation
- [x] 1. Package skeleton, coverage gate, mode state
- [x] 2. Settings (validated, persisted; NaN/infinity-safe)
- [x] 3. Window placement (default under camera; drop frames on missing displays)
- [x] 4. Markdown renderer
- [x] 5. Shrink-to-fit (main-actor isolated)
- [x] 6. File watcher (survives atomic saves; signals once when a file vanishes)
- [x] 7. Notes store (scratch, open file, save-back, reload; never overwrites what it can't read)
- [x] 7b. Mutation testing on Core — Muter 92% (46/50, measured at a82fb18; scope in `docs/mutation-testing.md`) + manual MarkdownRenderer spot-check
- [x] 8. App shell + ScreenFlow checkpoint — **passed 2026-11-24**: notes panel hidden, red control box recorded (keyboard check still open → Task 9)
- [x] 9. Edit/recording views, global hotkey ⌃⌥⌘N, CaptureShield (all helper windows hidden) — merged; hands-on check passed 2026-11-24 (checklist sections 1–3)
- [x] 10. File menu, appearance, persistence wiring — merged; files checked 2026-11-24 (section 4); quit alert and persistence (sections 5–6) not yet hand-tested
- [x] 11. Release v0.1.0 (manual checklist, README, tag, GitHub release) — published 2026-11-24 after checklist sections 1–4 passed

## Wrap-up
- [x] Whole-branch final review and its fix wave — approved 2026-11-24 (license notices, symlink save fix, README honesty, kept-scratch notice)

## After v0.1.0
- [x] Checklist section 5 (quit alert): 5.1 Return and 5.2 Escape passed by hand 2026-11-25; 5.3 automated
- [x] Checklist 6.1 (persistence across relaunch): automated, passing
- [x] `scripts/gui-checks.sh`: drives the built app through Accessibility (clicks only, no keystrokes); 14 checks passing
- [x] Fix: read-only files were overwritten by atomic saves (found by the GUI checks)
- [x] Fix: the red warning tint drew the menu-bar icon almost black on macOS 26; now a warning symbol
- [x] Release v0.1.2 (the two fixes)
- [x] 5.5 warning icon visible (Reuven, 2026-11-25)
- [ ] By hand: 5.4 focus after Cancel, 6.2 display unplug
- [ ] Section 7: download the release zip and confirm the Gatekeeper “Open Anyway” flow
- [x] App icon (original artwork in `docs/images`, `scripts/AppIcon.icns`) — released in v0.1.1
