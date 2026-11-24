import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// The shield hides every window the process owns from capture, except the three it must not
// touch, picked out by identity, never by level: the notes panel (its sharingType is written once,
// in init, and never again), the capture test window (it must stay recordable), and the status
// item's own window (the menu-bar icon). System popups often sit at or above status-bar level, so
// a level-based exemption would let them through.

@MainActor private func hide(
    panel: Bool = false, test: Bool = false, statusItem: Bool = false,
    _ sharing: NSWindow.SharingType = .readOnly
) -> Bool {
    CaptureShield.shouldHide(
        isNotesPanel: panel, isCaptureTestWindow: test, isStatusItemWindow: statusItem,
        sharingType: sharing)
}

@MainActor @Test func hidesAnOrdinaryRecordableWindow() {
    #expect(hide())
}

@MainActor @Test func leavesAlreadyHiddenWindowsAlone() {
    #expect(!hide(.none))
}

@MainActor @Test func neverWritesTheNotesPanel() {
    #expect(!hide(panel: true))
}

@MainActor @Test func leavesTheCaptureTestWindowRecordable() {
    #expect(!hide(test: true))
}

@MainActor @Test func leavesTheStatusItemWindowAlone() {
    #expect(!hide(statusItem: true))
}

/// An off-screen borderless window at `level`, standing in for a helper window macOS creates.
@MainActor private func helper(level: NSWindow.Level = .normal) -> NSWindow {
    let w = NSWindow(
        contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless],
        backing: .buffered, defer: false)
    w.level = level
    return w
}

@MainActor @Test func applyHidesHelpersAtAnyLevelButNotTheExemptWindows() {
    let low = helper()
    let popup = helper(level: .popUpMenu)
    let status = helper(level: .statusBar)
    let test = CaptureTestWindow(near: .zero, within: CGRect(x: 0, y: 0, width: 1440, height: 875))
    let panel = NotesPanel(settings: Settings())
    #expect(low.sharingType == .readOnly && popup.sharingType == .readOnly)
    CaptureShield.apply(to: [low, popup, status, test, panel], statusItemWindow: status)
    #expect(low.sharingType == .none && popup.sharingType == .none)
    #expect(status.sharingType == .readOnly)
    #expect(test.sharingType == .readOnly && panel.sharingType == .none)
}

@MainActor @Test func shieldCoversWindowsCreatedLaterOnEachEventLoopPass() {
    // The app posts didUpdateNotification after every event-loop pass; here it's posted by hand.
    let center = NotificationCenter()
    let status = helper(level: .statusBar)
    let shield = CaptureShield.start(center: center) { status }
    let later = helper(level: .popUpMenu)
    let test = CaptureTestWindow(near: .zero, within: CGRect(x: 0, y: 0, width: 1440, height: 875))
    for window in [later, test, status] { window.orderFrontRegardless() }
    defer { for window in [later, test, status] { window.orderOut(nil) } }
    #expect(later.sharingType == .readOnly)
    center.post(name: NSApplication.didUpdateNotification, object: nil)
    #expect(later.sharingType == .none && test.sharingType == .readOnly)
    #expect(status.sharingType == .readOnly)
    withExtendedLifetime(shield) {}
}

/// Runs one pass of the main run loop in `mode`, with a timer so the loop really waits (and so
/// passes through "before waiting").
@MainActor private func spin(_ mode: RunLoop.Mode) {
    let timer = Timer(timeInterval: 0.02, repeats: false) { _ in }
    RunLoop.main.add(timer, forMode: mode)
    RunLoop.main.run(mode: mode, before: .now + 0.2)
    timer.invalidate()
}

@MainActor @Test func shieldAlsoRunsWhileAMenuIsTracking() {
    // AppKit posts no didUpdateNotification while a menu tracks the mouse, and that's exactly when
    // the menu's own window first appears; seen on macOS 26.5: sharing 1 for the whole first open.
    let shield = CaptureShield.start(center: NotificationCenter()) { nil }
    let menuWindow = helper(level: .popUpMenu)
    menuWindow.orderFrontRegardless()
    defer { menuWindow.orderOut(nil) }
    spin(.eventTracking)
    #expect(menuWindow.sharingType == .none)
    withExtendedLifetime(shield) {}
}

@MainActor @Test func releasingTheShieldStopsIt() {
    let center = NotificationCenter()
    var shield: CaptureShield.Handle? = CaptureShield.start(center: center) { nil }
    #expect(shield != nil)
    shield = nil
    let later = helper()
    later.orderFrontRegardless()
    defer { later.orderOut(nil) }
    center.post(name: NSApplication.didUpdateNotification, object: nil)
    spin(.eventTracking)
    #expect(later.sharingType == .readOnly)
}
