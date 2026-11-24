import CoreGraphics

/// The sharing state the window server actually enforces for a window, or nil if it doesn't
/// know the window.
///
/// Why: AppKit's `sharingType` getter can report `.none` for a window that is in fact recordable
/// (seen on macOS 26.5), so the only trustworthy check is the window server's own record.
/// `kCGWindowSharingState` is 0 for none, 1 for read-only, 2 for read-write.
///
/// Lists all windows and filters, rather than asking for the one window with
/// `.optionIncludingWindow`: that query returned nothing in the test process (on screen or not),
/// while the full list includes the window there and in the app. The list is a few hundred
/// entries and this runs only at launch and on mode switches.
func windowServerSharingState(windowNumber: Int) -> Int? {
    // A nil list (window server unavailable) falls through the optional chain to nil: "unknown".
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    let match = windows?.first { $0[kCGWindowNumber as String] as? Int == windowNumber }
    return match?[kCGWindowSharingState as String] as? Int
}

/// The menu warning to show for the notes panel's window-server sharing state, or nil when the
/// panel is hidden from capture.
///
/// Why: anything other than a confirmed 0 (including an unknown window) means the notes might be
/// recorded, and the user must find out before recording, not after.
func captureWarning(sharingState: Int?) -> String? {
    sharingState == 0 ? nil : "⚠ Notes may be visible to recordings — quit and relaunch"
}

/// One window as the window server describes it: just what the stray-window check needs.
struct WindowServerWindow: Equatable {
    /// The window number (`NSWindow.windowNumber`).
    let number: Int
    /// `kCGWindowSharingState`: 0 none, 1 read-only, 2 read-write; nil if not reported.
    let sharingState: Int?
    /// Whether the window is currently ordered in (and so could be captured).
    let isOnScreen: Bool
}

/// Every window the window server lists for process `pid`, or nil if the window server gave no
/// list at all.
///
/// Why: the panel isn't the only window that could leak. macOS adds helper windows to our
/// process on its own (see `CaptureShield`), so the self-check has to look at all of them.
func windowServerWindows(ownedBy pid: pid_t) -> [WindowServerWindow]? {
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    return windows?.compactMap { window in
        guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
            let number = window[kCGWindowNumber as String] as? Int
        else { return nil }
        return WindowServerWindow(
            number: number, sharingState: window[kCGWindowSharingState as String] as? Int,
            isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

/// The menu warning if any of our windows is on screen and recordable, other than the windows
/// numbered in `allowed` (the capture test window and the status item's window). Otherwise nil.
///
/// Why: `CaptureShield` hides helper windows as they appear. This is the independent check that
/// it worked, read from the window server rather than AppKit. An unreported sharing state counts
/// as recordable, as it does for the panel, and so does a missing list (nil): what can't be
/// checked isn't trusted. Exemptions are by identity, not layer, because system popups often sit
/// at or above status-bar level.
func strayWindowWarning(_ windows: [WindowServerWindow]?, allowed: Set<Int>) -> String? {
    let stray =
        (windows?.contains {
            $0.isOnScreen && $0.sharingState != 0 && !allowed.contains($0.number)
        }) != false
    return stray ? captureWarning(sharingState: nil) : nil
}
