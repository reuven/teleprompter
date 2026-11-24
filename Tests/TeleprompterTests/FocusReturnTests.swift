import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// After a modal (Open…, the quit alert) activated the app: recording mode hands focus back to the
// app the user was in; edit mode gives it to the notes panel.

@MainActor @Test func recordingHandsFocusBackOnlyIfWeTookIt() {
    let other = NSWorkspace.shared.runningApplications.first { $0 != .current }
    #expect(
        FocusReturn.after(mode: .recording, appIsActive: true, previous: other)
            == other.map { .reactivate($0) } ?? FocusReturn.none)
    #expect(FocusReturn.after(mode: .recording, appIsActive: false, previous: other) == .none)
    #expect(FocusReturn.after(mode: .recording, appIsActive: true, previous: nil) == .none)
}

@MainActor @Test func editModeGivesFocusToThePanel() {
    #expect(FocusReturn.after(mode: .edit, appIsActive: true, previous: nil) == .makePanelKey)
    #expect(FocusReturn.after(mode: .edit, appIsActive: false, previous: nil) == .makePanelKey)
}

@MainActor @Test func previousAppIsNeverThisApp() {
    #expect(FocusReturn.previousApp(front: .current) == nil)
    #expect(FocusReturn.previousApp(front: nil) == nil)
    let other = NSWorkspace.shared.runningApplications.first { $0 != .current }
    #expect(FocusReturn.previousApp(front: other) == other)
}
