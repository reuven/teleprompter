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
/// - windows at status-bar level or above, which is how the menu-bar icon and its menus are
///   drawn. Those stay as AppKit made them so the icon behaves normally.
///
/// The shield runs after every event-loop pass (`NSApplication.didUpdateNotification`), so a
/// window created later is hidden before it's drawn on screen. It also runs once at launch and
/// after every mode switch. `CaptureCheck` then verifies the result with the window server.
@MainActor
enum CaptureShield {
    /// Whether a window with these traits should be set to `sharingType = .none`.
    static func shouldHide(
        isNotesPanel: Bool, isCaptureTestWindow: Bool, level: NSWindow.Level,
        sharingType: NSWindow.SharingType
    ) -> Bool {
        !isNotesPanel && !isCaptureTestWindow && level < .statusBar && sharingType != .none
    }

    /// Applies the rule to `windows` (in the app, `NSApp.windows`).
    static func apply(to windows: [NSWindow]) {
        for window in windows
        where shouldHide(
            isNotesPanel: window is NotesPanel, isCaptureTestWindow: window is CaptureTestWindow,
            level: window.level, sharingType: window.sharingType)
        {
            window.sharingType = .none
        }
    }

    /// Re-applies the rule to all of the app's windows after every event-loop pass. Keep the
    /// returned token for as long as the shield should stay up.
    static func start(center: NotificationCenter = .default) -> NSObjectProtocol {
        center.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply(to: NSApplication.shared.windows) }
        }
    }
}
