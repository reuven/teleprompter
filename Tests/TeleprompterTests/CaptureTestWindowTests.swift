import AppKit
import Testing

@testable import Teleprompter

/// Every view below `view`, at any depth, so a notes view nested anywhere would be found.
@MainActor private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
}

/// A 1440×875 visible area, like a laptop screen below the menu bar.
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

// The capture-test window is the positive control: it must be recordable, out of the way of the
// notes, and inert to the mouse.

@MainActor @Test(.tags(.guiSession)) func testWindowIsVisibleToCapture() {
    let w = CaptureTestWindow(near: CGRect(x: 100, y: 500, width: 640, height: 200), within: screen)
    #expect(w.sharingType == .readOnly)
}

@MainActor @Test(.tags(.guiSession)) func testWindowSitsDirectlyBelowThePanel() {
    let panel = CGRect(x: 100, y: 500, width: 640, height: 200)
    let w = CaptureTestWindow(near: panel, within: screen)
    #expect(w.frame.size == panel.size && w.frame.minX == panel.minX)
    #expect(w.frame.maxY == panel.minY - CaptureTestWindow.gap)
}

@MainActor @Test func flipsAbovePanelWhenNoRoomBelow() {
    let panel = CGRect(x: 100, y: 100, width: 640, height: 200)
    let f = CaptureTestWindow.frame(near: panel, within: screen)
    #expect(f.minY == panel.maxY + CaptureTestWindow.gap && f.size == panel.size)
}

@MainActor @Test func staysInsideVisibleFrame() {
    // Panel hanging off the right edge and taller than the room above and below it.
    let panel = CGRect(x: 1000, y: 100, width: 640, height: 700)
    let f = CaptureTestWindow.frame(near: panel, within: screen)
    #expect(screen.contains(f))
    #expect(f.maxX == screen.maxX && f.maxY == screen.maxY)
}

@MainActor @Test func usesScreenOffsetsForSecondaryDisplays() {
    let second = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
    let panel = CGRect(x: 2000, y: 600, width: 640, height: 200)
    let f = CaptureTestWindow.frame(near: panel, within: second)
    #expect(f == CGRect(x: 2000, y: 392, width: 640, height: 200))
}

@MainActor @Test(.tags(.guiSession)) func followMovesWindowWithPanel() {
    let w = CaptureTestWindow(near: CGRect(x: 100, y: 500, width: 640, height: 200), within: screen)
    let moved = CGRect(x: 300, y: 600, width: 500, height: 150)
    w.follow(moved, within: screen)
    #expect(w.frame == CaptureTestWindow.frame(near: moved, within: screen))
    #expect(w.frame.maxY == moved.minY - CaptureTestWindow.gap && w.frame.size == moved.size)
}

@MainActor @Test(.tags(.guiSession)) func testWindowIgnoresMouseAndFloats() {
    let w = CaptureTestWindow(near: .zero, within: screen)
    #expect(w.ignoresMouseEvents && w.level == .floating)
    #expect(!w.canBecomeKey && !w.canBecomeMain)
}

@MainActor @Test(.tags(.guiSession)) func testWindowIsMarkedRed() {
    let w = CaptureTestWindow(near: .zero, within: screen)
    #expect(w.contentView?.layer?.borderWidth == 4)
    #expect(w.warningLabel.stringValue == "VISIBLE TO RECORDING" && !w.warningLabel.isHidden)
}

@MainActor @Test(.tags(.guiSession)) func testWindowShowsOnlyFixedTestText() throws {
    let w = CaptureTestWindow(near: .zero, within: screen)
    #expect(
        w.textLabel.stringValue
            == "TEST — this red box SHOULD appear in your recording. Your notes panel next to it should not."
    )
    let content = try #require(w.contentView)
    #expect(!descendants(of: content).contains { $0 is NotesContentView || $0 is NSTextView })
}
