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

// Hardened check: besides the panel, any window of ours that is on screen and recordable is a
// leak, unless it's the capture test window (allowed by number) or at status-bar level or above.

private let warning = "⚠ Notes may be visible to recordings — quit and relaunch"

private func window(
    _ number: Int, sharing: Int? = 1, onScreen: Bool = true, layer: Int = 0
) -> WindowServerWindow {
    WindowServerWindow(number: number, sharingState: sharing, isOnScreen: onScreen, layer: layer)
}

@Test func hiddenOrOffScreenWindowsAreFine() {
    #expect(
        strayWindowWarning([window(1, sharing: 0), window(2, onScreen: false)], allowed: []) == nil)
    #expect(strayWindowWarning([], allowed: []) == nil)
}

@Test func onScreenRecordableWindowWarns() {
    #expect(strayWindowWarning([window(1, sharing: 0), window(7)], allowed: []) == warning)
    #expect(strayWindowWarning([window(7, sharing: nil)], allowed: []) == warning)
}

@Test func captureTestWindowIsAllowed() {
    #expect(strayWindowWarning([window(7)], allowed: [7]) == nil)
    #expect(strayWindowWarning([window(7), window(8)], allowed: [7]) == warning)
}

@Test func statusBarAndMenuLayersAreAllowed() {
    #expect(strayWindowWarning([window(1, layer: 25), window(2, layer: 101)], allowed: []) == nil)
    #expect(strayWindowWarning([window(1, layer: 24)], allowed: []) == warning)
}

@MainActor @Test func listsOnlyThisProcesssWindowsFromTheWindowServer() {
    // Far off screen: the window server lists it but reports it as not on screen, which is the
    // truth. (The test process can't put a window truly on screen; the app-launch check covers
    // the on-screen case.)
    let shown = NSPanel(
        contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless],
        backing: .buffered, defer: false)
    shown.sharingType = .readOnly
    shown.orderFrontRegardless()
    defer { shown.orderOut(nil) }
    let entry = windowServerWindows(ownedBy: getpid()).first { $0.number == shown.windowNumber }
    #expect(
        entry
            == WindowServerWindow(
                number: shown.windowNumber, sharingState: 1, isOnScreen: false, layer: 0))
    #expect(windowServerWindows(ownedBy: -1).isEmpty)
}
