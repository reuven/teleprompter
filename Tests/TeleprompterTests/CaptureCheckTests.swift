import AppKit
import Testing

@testable import Teleprompter

// The self-check reads what the window server actually enforces, because AppKit's own getter was
// shown to lie (it kept reporting .none for a recordable window).

@Test func hiddenWindowNeedsNoWarning() {
    #expect(captureWarning(sharingState: 0) == nil)
}

@Test func recordableOrUnknownWindowWarns() {
    let warning = "⚠ Notes may be visible to recordings — quit and relaunch"
    #expect(captureWarning(sharingState: 1) == warning)
    #expect(captureWarning(sharingState: 2) == warning)
    #expect(captureWarning(sharingState: nil) == warning)
}

@MainActor @Test func readsSharingStateFromWindowServer() {
    let hidden = NSPanel(
        contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless],
        backing: .buffered, defer: false)
    hidden.sharingType = .none
    let shown = NSPanel(
        contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless],
        backing: .buffered, defer: false)
    shown.sharingType = .readOnly
    // The window server only lists windows that have been ordered in; far off-screen is enough.
    hidden.orderFrontRegardless()
    shown.orderFrontRegardless()
    defer {
        hidden.orderOut(nil)
        shown.orderOut(nil)
    }
    #expect(windowServerSharingState(windowNumber: hidden.windowNumber) == 0)
    #expect(windowServerSharingState(windowNumber: shown.windowNumber) == 1)
}

@Test func unknownWindowHasNoSharingState() {
    #expect(windowServerSharingState(windowNumber: 0) == nil)
}
