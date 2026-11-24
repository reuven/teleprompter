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
- [ ] 6. File watcher (survives atomic saves) — *in progress*
- [ ] 7. Notes store (scratch, open file, save-back, reload) + Muter mutation testing on Core
- [ ] 8. App shell + **ScreenFlow checkpoint with Reuven**
- [ ] 9. Edit/recording views, global hotkey ⌃⌥⌘N
- [ ] 10. File menu, appearance, persistence wiring
- [ ] 11. Release v0.1.0 (manual checklist, README, tag, GitHub release)

## Wrap-up
- [ ] Whole-branch final review and its fix wave (includes the deferred minor findings)
