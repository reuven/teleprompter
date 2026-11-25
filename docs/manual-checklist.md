# Manual release checklist

Run this before every release, on the built app (`scripts/build-app.sh`, then open
`build/Teleprompter.app`). Automated tests cannot see ScreenFlow, other apps' focus, or a
second display, so these checks are the real gate. Each step has an Expected line. Copy this
file's checkboxes into the release issue or notes and tick them for that release; the boxes
here stay empty.

Release: ______  Date: ______  macOS: ______  ScreenFlow: ______

**Run `scripts/gui-checks.sh` first** (after `scripts/build-app.sh`, with Teleprompter quit).
It drives the built app through Accessibility, with clicks only and never keystrokes, and
prints PASS or FAIL for the items marked *(automated)* below: the quit alert's buttons and
default, refusing to overwrite a read-only file, persistence across a relaunch, the capture
setting as the window server reports it, and the bundle's architectures and Gatekeeper policy.
It needs Accessibility permission for your terminal app (System Settings › Privacy & Security
› Accessibility), backs up and restores your own settings, and takes about a minute. Tick an
automated item when the script passed it; everything else here still needs you.

## 1. ScreenFlow recording (first, and the one that matters most)

Start a ScreenFlow screen recording of the display the panel is on, then do the steps below
while it runs. Review the recording afterward, frame by frame where noted.

- [ ] **1.1 Panel is hidden.** Show the panel in recording mode with real text.
  Expected: the notes panel is absent from the recording.
- [ ] **1.2 Capture test box.** Choose Show in Recordings (Test) from the menu.
  Expected: a red-bordered "VISIBLE TO RECORDING" test box appears in the recording, then
  disappears when the test is switched off. This proves the recording would show a window if
  one leaked.
- [ ] **1.3 Status menu.** Open the menu-bar menu while recording.
  Expected: the menu is absent from its very first frame in the recording.
- [ ] **1.4 Editor context menu.** In edit mode, right-click in the text.
  Expected: the context menu is absent from its first frame.
- [ ] **1.5 Look Up / Services.** In edit mode, press ⌃⌘D on a word.
  Expected: nothing appears in the recording.
- [ ] **1.6 Caret and input source.** In edit mode, type in the panel, toggle Caps Lock, and
  switch input source (for example to Hebrew and back).
  Expected: no caret, Caps Lock indicator, or input-source indicator appears in the recording.
- [ ] **1.7 Full-screen app.** Put another app in full screen (its own Space) with the panel
  floating above it.
  Expected: the panel stays visible to you, stays absent from the recording.
- [ ] **1.8 Two displays.** Attach a second display and relaunch.
  Expected: no false "Notes may be visible to recordings — quit and relaunch" warning, and
  the panel is still absent from the recording.
- [ ] **1.9 Capture test is not remembered.** Leave Show in Recordings (Test) on, quit, and
  relaunch.
  Expected: no red test box after relaunch.
- [ ] **1.10 Timer.** With a target of 0:15, press ⌃⌥⌘T while recording and let it run
  past the target, then press it again.
  Expected: the timer strip is absent from the recording, like the notes. On your screen the
  time turns amber at 0:10, red at 0:15, and stays frozen after the second press.

## 2. Focus

- [ ] **2.1 Lock returns focus.** From TextEdit (then Safari), choose Edit Notes, then Lock for
  Recording, then type.
  Expected: the typing lands in the other app.
- [ ] **2.2 Launch with empty notes.** Quit, empty the notes (or use a fresh scratch file), and
  launch while typing in another app.
  Expected: the app opens in edit mode but does not steal your keystrokes until you click it.
- [ ] **2.3 Click-through.** In recording mode, click the panel's area over another app.
  Expected: the click reaches the app underneath, and the panel never takes focus.
- [ ] **2.4 Hotkey from another app.** With Safari in front, press ⌃⌥⌘N (the physical N key).
  Expected: the panel switches mode; Safari keeps focus when you go to recording mode.

## 3. Editing

- [ ] **3.1 Edit commands.** In edit mode, use ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z and ⌘⇧Z.
  Expected: each works as in any text field.
- [ ] **3.2 Edit commands, Hebrew input source.** Switch to a Hebrew input source and repeat 3.1.
  Expected: the same shortcuts still work.
- [ ] **3.3 Text size.** Press ⌘+ and ⌘− in the panel, then use Larger/Smaller Text in the menu.
  Expected: the size steps up and down both ways.
- [ ] **3.4 Text size, Hebrew input source.** Repeat 3.3's ⌘+ and ⌘− with a Hebrew source.
  Expected: they still work.
- [ ] **3.5 Markdown and shrink-to-fit.** Type headings, lists, bold, and italic; resize the
  panel smaller.
  Expected: recording mode renders the Markdown; text shrinks to fit; at the minimum size the
  "▼ more below" badge appears.

## 4. Files

- [ ] **4.1 Open… from recording mode.** Choose Open… while locked for recording.
  Expected: the open dialog comes forward; after choosing or cancelling, focus returns to the
  app you were in. The Open… dialog (including its file preview) and the menu-bar icon are not
  hidden from recordings; open files before you start recording.
- [ ] **4.2 Open Recent.** Open two files, then pick the first from Open Recent.
  Expected: it opens, and the list shows the most recent first.
- [ ] **4.3 Close File.** Choose Close File.
  Expected: the panel shows your scratch notes, which were not changed by the open file.
- [ ] **4.4 Edits save back.** Edit an open file in the panel and wait a couple of seconds.
  Expected: the file on disk changes.
- [ ] **4.5 External edit.** Edit the open file in another editor and save.
  Expected: the panel updates live.
- [ ] **4.6 Atomic-save editors.** Repeat 4.5 with vim and BBEdit (they replace the file on
  save), twice in a row each.
  Expected: every save still reloads.
- [ ] **4.7 Deleted file.** Delete the open file.
  Expected: an error line appears at the top of the menu and the app falls back to scratch.

## 5. Quit alert

Simulate a save problem: make the open file read-only (`chmod a-w file.md`) or lock it
(Finder › Get Info › Locked, or `chflags uchg file.md`), then edit in the panel and choose
Quit. Undo afterward (`chmod u+w` / `chflags nouchg`).

Return, Escape and focus can't be scripted faithfully (macOS won't bring a scripted app to
the front), so 5.1, 5.2 and 5.4 stay manual. Quit from the menu yourself.

- [ ] **5.1 Return cancels.** Press Return in the alert.
  Expected: the alert closes, the app keeps running, nothing quits.
- [ ] **5.2 Escape.** Quit again and press Escape.
  Expected: Escape cancels or does nothing; it never quits. (Return stays Cancel, as in 5.1.)
- [ ] **5.3 Quit Anyway** is destructive and never the default. *(automated)*
  Expected: only an explicit click on Quit Anyway quits; Cancel is the default.
- [ ] **5.5 Warning icon.** While the save error shows, look at the menu bar.
  Expected: the icon is a bubble with an exclamation mark, as easy to see as the other
  menu-bar icons; it goes back to the plain bubble after Dismiss.
- [ ] **5.6 Read-only file.** *(automated)*
  Expected: an edit to a read-only file is not saved, and the file keeps its content.
- [ ] **5.4 Focus after Cancel.** Do 5.1 from recording mode.
  Expected: focus returns to the previous app.

## 6. Persistence

Set a non-default panel position and size, font size, opacity, and open a file; quit normally
and relaunch.

- [ ] **6.1 Relaunch.** *(automated)*
  Expected: frame, font size, opacity, and last file all come back.
- [ ] **6.2 Display unplug.** With the panel on an external display, unplug it.
  Expected: the panel comes back at the default position, and relaunching does not restore
  the frame macOS moved it to (the saved frame is not overwritten by the system move).

## 7. Gatekeeper (release zip only)

- [ ] **7.1 Quarantined download.** Download the release zip from GitHub in a browser (so it is
  quarantined) to a clean folder, unzip, move to /Applications, and open it.
  Expected: macOS blocks the first open. (The script checks the policy on a copy it
  quarantines itself; the real download and the dialog are yours.)
- [ ] **7.2 Open Anyway.** System Settings › Privacy & Security › Open Anyway, then confirm.
  Expected: the app launches on macOS 26, with a menu-bar icon and no Dock icon.
- [ ] **7.3 Version.** Check the version line in the menu-bar menu (above Quit) and Finder ›
  Get Info. *(the menu line is automated)*
  Expected: it matches the release; `lipo -archs` of the binary shows arm64 and x86_64
  (the architectures are *automated*).
