import AppKit

/// Hides from screen capture every window this app owns, apart from three it must not touch.
///
/// Why: macOS creates helper windows inside our process that we never asked for, and they are
/// recordable by default. Seen on macOS 26.5: as soon as an *editable* NSTextView exists, AppKit
/// adds a `TUINSWindow` (TextInputUI). It is 500×500, off screen, and sharing state 1. It never
/// held notes text, but once the user types it hosts a 64×64 remote view, probably the caret's
/// input-source / Caps Lock indicator. When that shows, it would appear in recordings right next
/// to the hidden notes panel. Dictation, emoji and character pickers, and future helpers may
/// behave the same, so the rule is general, not keyed to a class name.
///
/// The rule: set `.none` on every window we own whose `sharingType` isn't already `.none`,
/// except:
/// - the `NotesPanel`, whose `sharingType` is written once, in init, and never again (not even
///   the same value), because on macOS 26.5 re-setting it can silently fail;
/// - the `CaptureTestWindow`, which must stay recordable: it's the positive control;
/// - the status item's own window (the menu-bar icon), left as AppKit made it.
///
/// Exemptions are by identity, never by window level: system popups (input-method candidates,
/// emoji picker, completion lists, tooltips, pop-up menus) often sit at or above status-bar
/// level, so a level rule would let exactly those through.
///
/// The shield runs after every event-loop pass (`NSApplication.didUpdateNotification`), so a
/// window created later is hidden before it's drawn on screen. It also runs once at launch and
/// after every mode switch. `CaptureCheck` then verifies the result with the window server.
@MainActor
enum CaptureShield {
    /// Whether a window with these traits should be set to `sharingType = .none`.
    static func shouldHide(
        isNotesPanel: Bool, isCaptureTestWindow: Bool, isStatusItemWindow: Bool,
        sharingType: NSWindow.SharingType
    ) -> Bool {
        !isNotesPanel && !isCaptureTestWindow && !isStatusItemWindow && sharingType != .none
    }

    /// Applies the rule to `windows` (in the app, `NSApp.windows`); `statusItemWindow` is the
    /// menu-bar icon's window, if it has one.
    static func apply(to windows: [NSWindow], statusItemWindow: NSWindow?) {
        for window in windows
        where shouldHide(
            isNotesPanel: window is NotesPanel, isCaptureTestWindow: window is CaptureTestWindow,
            isStatusItemWindow: window === statusItemWindow, sharingType: window.sharingType)
        {
            window.sharingType = .none
        }
    }

    /// Re-applies the rule to all of the app's windows after every event-loop pass. Keep the
    /// returned token for as long as the shield should stay up.
    ///
    /// `statusItemWindow` is asked on each pass, since the icon's window can be recreated.
    static func start(
        center: NotificationCenter, statusItemWindow: @escaping @MainActor () -> NSWindow?
    ) -> NSObjectProtocol {
        center.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                apply(to: NSApplication.shared.windows, statusItemWindow: statusItemWindow())
            }
        }
    }
}
