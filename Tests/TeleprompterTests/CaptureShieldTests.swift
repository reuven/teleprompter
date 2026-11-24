import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// The shield hides every window the process owns from capture, except the three it must not
// touch: the notes panel (its sharingType is written once, in init, and never again), the capture
// test window (it must stay recordable), and status-bar-level windows (the menu-bar icon).

@MainActor @Test func hidesAnOrdinaryRecordableWindow() {
    #expect(
        CaptureShield.shouldHide(
            isNotesPanel: false, isCaptureTestWindow: false, level: .normal, sharingType: .readOnly)
    )
    #expect(
        CaptureShield.shouldHide(
            isNotesPanel: false, isCaptureTestWindow: false, level: .floating,
            sharingType: .readOnly))
}

@MainActor @Test func leavesAlreadyHiddenWindowsAlone() {
    #expect(
        !CaptureShield.shouldHide(
            isNotesPanel: false, isCaptureTestWindow: false, level: .normal, sharingType: .none))
}

@MainActor @Test func neverWritesTheNotesPanel() {
    #expect(
        !CaptureShield.shouldHide(
            isNotesPanel: true, isCaptureTestWindow: false, level: .floating, sharingType: .readOnly
        ))
}

@MainActor @Test func leavesTheCaptureTestWindowRecordable() {
    #expect(
        !CaptureShield.shouldHide(
            isNotesPanel: false, isCaptureTestWindow: true, level: .floating, sharingType: .readOnly
        ))
}

@MainActor @Test func leavesStatusBarLevelWindowsAlone() {
    for level: NSWindow.Level in [.statusBar, .popUpMenu, .screenSaver] {
        #expect(
            !CaptureShield.shouldHide(
                isNotesPanel: false, isCaptureTestWindow: false, level: level,
                sharingType: .readOnly))
    }
    #expect(
        CaptureShield.shouldHide(
            isNotesPanel: false, isCaptureTestWindow: false,
            level: NSWindow.Level(NSWindow.Level.statusBar.rawValue - 1), sharingType: .readOnly))
}

@MainActor @Test func applyHidesHelpersButNotTheTestWindowOrPanel() {
    let helper = NSWindow(
        contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless],
        backing: .buffered, defer: false)
    let test = CaptureTestWindow(near: .zero, within: CGRect(x: 0, y: 0, width: 1440, height: 875))
    let panel = NotesPanel(settings: Settings())
    #expect(helper.sharingType == .readOnly)
    CaptureShield.apply(to: [helper, test, panel])
    #expect(helper.sharingType == .none)
    #expect(test.sharingType == .readOnly && panel.sharingType == .none)
}

@MainActor @Test func shieldCoversWindowsCreatedLaterOnEachEventLoopPass() {
    // The app posts didUpdateNotification after every event-loop pass; here it's posted by hand.
    let center = NotificationCenter()
    let token = CaptureShield.start(center: center)
    defer { center.removeObserver(token) }
    let later = NSWindow(
        contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless],
        backing: .buffered, defer: false)
    let test = CaptureTestWindow(near: .zero, within: CGRect(x: 0, y: 0, width: 1440, height: 875))
    later.orderFrontRegardless()
    test.orderFrontRegardless()
    defer {
        later.orderOut(nil)
        test.orderOut(nil)
    }
    #expect(later.sharingType == .readOnly)
    center.post(name: NSApplication.didUpdateNotification, object: nil)
    #expect(later.sharingType == .none && test.sharingType == .readOnly)
}
