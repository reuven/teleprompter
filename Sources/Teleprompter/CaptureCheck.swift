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
