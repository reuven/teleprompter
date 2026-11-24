import AppKit
import Testing

@testable import Teleprompter

// Quitting must never drop notes silently: with unsaved changes the user is asked, and the safe
// answer (Cancel) is the default.

@MainActor @Test func quitsWithoutAskingWhenEverythingIsSaved() {
    var asked = false
    #expect(
        QuitDecision.shouldQuit(hasUnsavedChanges: false) {
            asked = true
            return .alertFirstButtonReturn
        })
    #expect(!asked)
}

@MainActor @Test func unsavedChangesQuitOnlyOnQuitAnyway() {
    #expect(!QuitDecision.shouldQuit(hasUnsavedChanges: true) { .alertFirstButtonReturn })
    #expect(QuitDecision.shouldQuit(hasUnsavedChanges: true) { .alertSecondButtonReturn })
    #expect(!QuitDecision.shouldQuit(hasUnsavedChanges: true) { .abort }, "anything else stays")
}

@MainActor @Test func alertSaysWhyAndDefaultsToCancel() {
    let alert = QuitDecision.makeAlert(detail: "Couldn't save “talk.md”.")
    #expect(alert.messageText == "Your notes couldn't be saved")
    #expect(alert.informativeText.contains("talk.md"))
    #expect(alert.buttons.map(\.title) == ["Cancel", "Quit Anyway"])
    #expect(alert.buttons[0].keyEquivalent == "\r", "Return cancels")
    #expect(alert.alertStyle == .warning)
    #expect(!QuitDecision.makeAlert(detail: nil).informativeText.isEmpty)
}

@MainActor @Test func quitAnywayIsMarkedDestructive() {
    let alert = QuitDecision.makeAlert(detail: nil)
    #expect(alert.buttons[1].hasDestructiveAction && !alert.buttons[0].hasDestructiveAction)
}
