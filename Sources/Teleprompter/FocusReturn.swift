import AppKit
import TeleprompterCore

/// Where keyboard focus goes after a modal dialog (Open…, the quit alert) had to activate the
/// app.
///
/// Why: recording mode must never keep focus, so typing goes back to the app being recorded, as
/// Lock for Recording does; in edit mode the user was typing notes, so the panel takes focus
/// again. One rule for every modal, so they can't drift apart.
enum FocusReturn: Equatable {
    /// Hand focus back to the app that was frontmost before the dialog.
    case reactivate(NSRunningApplication)
    /// Make the notes panel key again.
    case makePanelKey
    /// Leave focus where it is.
    case none

    /// The rule: edit mode → the panel; recording mode → the previous app, but only if this app
    /// is still active (if the user already switched away, focus is theirs to keep).
    static func after(mode: Mode, appIsActive: Bool, previous: NSRunningApplication?) -> Self {
        switch mode {
        case .edit: return .makePanelKey
        case .recording:
            guard appIsActive, let previous else { return .none }
            return .reactivate(previous)
        }
    }

    /// The app to return to: the frontmost one before the dialog, unless that's this app.
    static func previousApp(front: NSRunningApplication?) -> NSRunningApplication? {
        front == NSRunningApplication.current ? nil : front
    }
}
