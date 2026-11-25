#!/usr/bin/env bash
# Runs the manual checklist's mechanical checks against the real app by driving it through
# Accessibility (AppleScript + System Events): the quit alert (section 5, except the keys),
# persistence across a relaunch (6.1), and the bundle checks that need no clicking (7.1 policy,
# 7.3).
#
# Why a script: these checks are about real AppKit behavior (a modal alert's buttons and
# default, refusing to overwrite a read-only file, what a relaunch restores), which unit tests can't see, but they need
# no human judgment, so they can be rerun identically before every release. What still needs a
# person (ScreenFlow, unplugging a display, clicking Open Anyway) stays in
# docs/manual-checklist.md.
#
# Requirements: a logged-in GUI session; Accessibility permission for the terminal app
# (System Settings › Privacy & Security › Accessibility); Teleprompter not already running.
# It never sends keystrokes (keys go to whichever app is frontmost, and a stray Escape in the
# terminal interrupts Claude Code); everything is Accessibility clicks and values. Menus and
# the panel move on screen for about a minute, so leave the mouse alone while it runs.
# Your own settings and scratch notes are backed up first and restored at the end.
#
# Usage: scripts/gui-checks.sh [path/to/Teleprompter.app]   (default: build/Teleprompter.app)
# Exit status: 0 if every check passed, 1 if any failed, 2 if it couldn't run.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/Teleprompter.app}"
bundle_id="co.lerner.teleprompter"
support="$HOME/Library/Application Support/Teleprompter"

if [[ ! -d "$app" ]]; then
    echo "No app at $app; run scripts/build-app.sh first." >&2
    exit 2
fi
if pgrep -x Teleprompter >/dev/null; then
    echo "Teleprompter is running; quit it first (this script launches its own copy)." >&2
    exit 2
fi
if ! osascript -e 'tell application "System Events" to get name of menu bar 1 of process "Finder"' \
    >/dev/null 2>&1; then
    echo "No Accessibility permission: allow your terminal app in System Settings ›" \
        "Privacy & Security › Accessibility." >&2
    exit 2
fi

work="$(mktemp -d)"
notes="$work/notes.md"
original=$'# Test notes\n\n- first point\n- second point'
printf '%s\n' "$original" >"$notes"

# Back up the user's settings and scratch notes; restore them however the script ends.
had_defaults=no
if defaults export "$bundle_id" "$work/defaults.plist" 2>/dev/null; then had_defaults=yes; fi
had_support=no
if [[ -d "$support" ]]; then
    cp -Rp "$support" "$work/support"
    had_support=yes
fi
restore() {
    jobs -p | xargs kill 2>/dev/null || true
    pkill -x Teleprompter 2>/dev/null || true
    for _ in {1..25}; do pgrep -x Teleprompter >/dev/null || break; sleep 0.2; done
    if [[ $had_defaults == yes ]]; then
        defaults delete "$bundle_id" 2>/dev/null || true
        defaults import "$bundle_id" "$work/defaults.plist"
    else
        defaults delete "$bundle_id" 2>/dev/null || true
    fi
    if [[ $had_support == yes ]]; then rsync -a --delete "$work/support/" "$support/"; fi
    chflags -R nouchg "$work" 2>/dev/null || true
    chmod -R u+w "$work"
    rm -rf "$work"
}
trap restore EXIT

swiftc -O scripts/window-info.swift -o "$work/window-info"

failures=0
# check ID DESCRIPTION COMMAND...: runs COMMAND and prints PASS or FAIL for the checklist item.
check() {
    local id="$1" description="$2"
    shift 2
    if "$@"; then
        echo "PASS  $id  $description"
    else
        echo "FAIL  $id  $description"
        failures=$((failures + 1))
    fi
}
same() { [[ "$1" == "$2" ]] || { echo "      expected '$2', got '$1'" >&2; false; }; }

# AppleScript statements run inside `tell process "Teleprompter"`.
ax() {
    osascript -e 'tell application "System Events" to tell process "Teleprompter"' \
        -e "$1" -e 'end tell'
}
# Clicks a status-menu item, or an item in one of its submenus: menu ITEM | menu SUBMENU ITEM.
menu() {
    local root='menu 1 of menu bar item 1 of menu bar 1'
    if [[ $# == 1 ]]; then
        ax "click menu bar item 1 of menu bar 1
            delay 0.3
            click menu item \"$1\" of $root" >/dev/null
    else
        ax "click menu bar item 1 of menu bar 1
            delay 0.3
            click menu item \"$1\" of $root
            delay 0.3
            click menu item \"$2\" of menu 1 of menu item \"$1\" of $root" >/dev/null
    fi
    sleep 0.5
}
# Waits up to ~5 s for COMMAND to succeed.
wait_until() {
    for _ in {1..25}; do "$@" && return 0; sleep 0.2; done
    return 1
}
running() { pgrep -x Teleprompter >/dev/null; }
stopped() { ! running; }
panel_shown() { [[ "$(ax 'count windows' 2>/dev/null)" -ge 1 ]]; }
launch() {
    open "$app"
    wait_until running && wait_until panel_shown
    sleep 1
}
frame() {
    ax 'set {x, y} to position of window 1
        set {w, h} to size of window 1
        return (x as text) & "," & y & "," & w & "," & h'
}
# The panel's text: a bare text view in recording mode, inside a scroll view in edit mode.
notes_text() {
    ax 'try
            return value of text area 1 of window 1
        on error
            return value of text area 1 of scroll area 1 of window 1
        end try'
}
# The check mark on an Opacity submenu item ("✓" when chosen); closes the menu again.
opacity_mark() {
    ax "click menu bar item 1 of menu bar 1
        delay 0.3
        set root to menu 1 of menu bar item 1 of menu bar 1
        click menu item \"Opacity\" of root
        delay 0.3
        set mark to value of attribute \"AXMenuItemMarkChar\" of menu item \"$1\" of menu 1 of menu item \"Opacity\" of root
        try
            perform action \"AXCancel\" of root
        on error
            click menu bar item 1 of menu bar 1
        end try
        return mark"
}
window_server() { "$work/window-info" "$(pgrep -x Teleprompter)"; }
setting() {
    defaults export "$bundle_id" - | plutil -extract 'settings\.v1' raw -o - - | base64 -d |
        plutil -extract "$1" raw -o - -
}
# Number of the alert window (the one with a "Quit Anyway" button), or 0 when none is open.
alert_window() {
    ax 'repeat with i from 1 to count windows
            if exists button "Quit Anyway" of window i then return i
        end repeat
        return 0'
}
alert_open() { [[ "$(alert_window)" != 0 ]]; }
alert_closed() { ! alert_open; }
# Sends Quit as an Apple Event, in the background: while the alert is up the app is in a modal
# loop and the event's reply waits for it, so a foreground call would deadlock the script.
quit_async() {
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 &
}

# The settings this run starts from: defaults, plus the test file as the last file.
json="{\"fontSize\":32,\"opacity\":0.85,\"lastFileURL\":\"file://$notes\",\"recentFiles\":[\"file://$notes\"]}"
defaults delete "$bundle_id" 2>/dev/null || true
defaults write "$bundle_id" settings.v1 -data "$(printf '%s' "$json" | xxd -p | tr -d '\n')"

echo "Running GUI checks on $app — leave the mouse alone until it finishes (about a minute)."

# --- 6.1 Persistence -------------------------------------------------------------------------
launch
menu "Larger Text"
menu "Larger Text"
menu "Opacity" "70%"
ax 'set position of window 1 to {300, 400}
    set size of window 1 to {700, 260}' >/dev/null
sleep 2 # the frame is saved 0.5 s after the last move
frame_before="$(frame)"
menu "Quit"
check 6.1a "Quit with nothing unsaved quits without asking" wait_until stopped
launch
check 6.1b "Relaunch restores the panel's position and size" same "$(frame)" "$frame_before"
check 6.1c "Relaunch restores the text size (36 pt)" same "$(setting fontSize)" 36
# Opacity applies to the panel's background only (the text stays solid), so the window
# server's alpha is always 1; the saved setting and the menu's check mark are what to compare.
# The setting reads back as 0.700000, so compare numerically.
opacity_restored() {
    awk -v o="$(setting opacity)" 'BEGIN { exit !(o == 0.7) }' && [[ "$(opacity_mark 70%)" == ✓ ]]
}
check 6.1d "Relaunch restores the opacity (70%)" opacity_restored
check 6.1e "Relaunch reopens the last file" grep -q "first point" <<<"$(notes_text)"
check 1.x "Notes panel is hidden from capture (window server)" \
    same "$(window_server | cut -d' ' -f2)" 0

# --- 5. Quit alert -------------------------------------------------------------------------
# Driven by Accessibility clicks only, never keystrokes. macOS declines to bring an app forward
# for a scripted quit, so Return and Escape in the alert (5.1, 5.2) and focus after Cancel
# (5.4) can't be tested faithfully here; they stay in the manual checklist.
chmod a-w "$notes" # read-only: the app must refuse to save rather than replace the file
menu "Edit Notes"
ax 'set value of text area 1 of scroll area 1 of window 1 to "# Test notes
- EDITED"' >/dev/null # an Accessibility edit counts as typing
sleep 2 # the save is tried 0.5 s after the edit, and must fail on the read-only file
if ! grep -q EDITED <<<"$(notes_text)"; then
    echo "FAIL  5     Couldn't edit the panel, so the quit alert can't be tested"
    failures=$((failures + 1))
else
    check 5.0 "An edit to a read-only file is refused, not saved" \
        same "$(cat "$notes")" "$original"
    quit_async
    if ! wait_until alert_open; then
        echo "FAIL  5     Quit with unsaved changes showed no alert"
        failures=$((failures + 1))
    else
        w="$(alert_window)"
        buttons="$(ax "return name of buttons of window $w")"
        default="$(ax "return name of (value of attribute \"AXDefaultButton\" of window $w)")"
        check 5.3a "The alert offers Cancel and Quit Anyway" same "$buttons" "Cancel, Quit Anyway"
        check 5.3b "Cancel is the default button (Return), not Quit Anyway" same "$default" Cancel

        ax "click button \"Cancel\" of window $w" >/dev/null
        sleep 1
        cancelled() { running && alert_closed; }
        check 5.3c "Cancel closes the alert and the app keeps running" cancelled

        quit_async
        wait_until alert_open || true
        w="$(alert_window)"
        ax "click button \"Quit Anyway\" of window $w" >/dev/null
        check 5.3d "Clicking Quit Anyway quits" wait_until stopped
    fi
fi
check 5.x "The read-only file was left untouched" same "$(cat "$notes")" "$original"

# --- 7. The app bundle (Gatekeeper policy and version; the clicking stays manual) ----------
plist="$app/Contents/Info.plist"
check 7.3a "Universal binary (arm64 + x86_64)" \
    eval "lipo -archs '$app/Contents/MacOS/Teleprompter' | grep -q arm64 &&
        lipo -archs '$app/Contents/MacOS/Teleprompter' | grep -q x86_64"
echo "      version $(plutil -extract CFBundleShortVersionString raw "$plist")" \
    "(build $(plutil -extract CFBundleVersion raw "$plist"))"
cp -R "$app" "$work/Quarantined.app"
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$work/Quarantined.app"
check 7.1 "Gatekeeper blocks the downloaded (unnotarized) app on first open" \
    eval "! spctl --assess --type execute '$work/Quarantined.app' 2>/dev/null"

echo
if [[ $failures == 0 ]]; then
    echo "All GUI checks passed."
else
    echo "$failures GUI check(s) failed."
    exit 1
fi
