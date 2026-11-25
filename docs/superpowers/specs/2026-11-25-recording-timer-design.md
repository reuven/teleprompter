# Recording timer — design

Date: 2026-11-25
Status: draft, awaiting Reuven's approval

## Intent

Reuven records ads with fixed lengths (30 seconds, a minute) as well as longer course and
YouTube videos. He wants to see how long he has been talking without looking away from the
camera: a timer in the notes panel, readable by him and, like the notes, absent from the
recording.

## Goals

- A count-up timer in the notes panel, started and stopped by its own global shortcut.
- An optional target length, set in the menu, that the timer warns about as it approaches and
  passes it.
- Never visible in a recording, and never in the way when he isn't using it.

## Non-goals

- Detecting when ScreenFlow starts recording (macOS offers no way to know).
- Pausing mid-take, lap times, a countdown display, typed custom targets.
- Sound or notifications at the target (they would end up in the recording's audio or on
  screen).

## Approaches

1. **A timer strip inside the notes panel — chosen.** It inherits the panel's hiding,
   position, opacity and click-through, so it adds no new window that could leak into a
   recording. Cost: while the timer shows, the notes fit into slightly less height.
2. A separate timer window. Freely placed, but a second hidden window to keep hidden, place
   and remember; the macOS 26.5 re-hide bug makes every extra window a risk. Rejected.
3. The time appended as the notes' last line. Cheapest, but the notes would re-fit every
   second and could jump in size. Rejected.

## Decided with Reuven

- **Starts by its own global shortcut, ⌃⌥⌘T** (not by entering recording mode), so it
  starts when he starts talking.
- **Counts up, with an optional target** chosen in the menu. Display: `0:42`, or
  `0:42 / 1:00` with a target.
- **One key cycles start → stop → restart:** the first press starts from 0:00; the second
  stops and keeps the final time on screen; the third resets to 0:00 and starts again.
- **Hidden until first used:** the strip appears on the first press; a **Hide Timer** menu
  item puts it away (and resets it).
- **Target presets:** Off, 0:15, 0:30, 0:45, 1:00, 1:30, 2:00, 3:00 (no typed values: a dialog
  is a hiding risk while recording).
- **Colors:** normal text color until 5 seconds before the target, amber in those last 5
  seconds, red once past it. No target: always the normal color.

## My calls (correct any of these)

- The timer works the same in edit and recording mode; switching modes doesn't touch it.
- The target is remembered across launches (part of `Settings`); the running timer is not.
- Elapsed time comes from a monotonic clock (`ContinuousClock`), so changing the system clock
  or sleep/wake can't make it jump backward; the display refreshes a few times a second.
- Past an hour it shows `1:02:03`.
- The strip sits at the bottom right in a fixed, readable size (independent of the notes'
  shrink-to-fit), in a monospaced-digit font so the numbers don't wobble.
- Menu: a **Start Timer / Stop Timer / Restart Timer** item (the title follows the state,
  showing ⌃⌥⌘T), **Hide Timer** (only while it shows), and a **Timer Target ▸** submenu with
  a check mark on the current preset.
- If ⌃⌥⌘T can't be registered, the menu says so, as it does for ⌃⌥⌘N, and the menu item
  still works.

## Build notes

- Pure logic in `TeleprompterCore` under the 100% coverage gate: the timer's state machine
  (hidden / running / stopped, elapsed from an injected clock), the display text, and the
  color thresholds. Property tests for the formatting (any duration) and the thresholds
  (monotonic: normal → amber → red as time grows).
- The AppKit side stays thin: a label in `NotesPanel`, a second `HotKey`, menu items through
  `MenuModel`, and the strip's height taken out of the fitting area in recording mode.
- `scripts/gui-checks.sh` gains checks that the strip appears, counts, stops and hides, and
  that the panel stays hidden from capture with it showing.
