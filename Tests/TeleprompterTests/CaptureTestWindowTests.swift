import AppKit
import Testing

@testable import Teleprompter

// The capture-test window is the positive control: it must be recordable, out of the way of the
// notes, and inert to the mouse.

@MainActor @Test func testWindowIsVisibleToCapture() {
    let w = CaptureTestWindow(
        below: CGRect(x: 100, y: 500, width: 640, height: 200))
    #expect(w.sharingType == .readOnly)
}

@MainActor @Test func testWindowSitsDirectlyBelowThePanel() {
    let panel = CGRect(x: 100, y: 500, width: 640, height: 200)
    let w = CaptureTestWindow(below: panel)
    #expect(w.frame.size == panel.size && w.frame.minX == panel.minX)
    #expect(w.frame.maxY == panel.minY - CaptureTestWindow.gap)
}

@MainActor @Test func testWindowIgnoresMouseAndFloats() {
    let w = CaptureTestWindow(below: .zero)
    #expect(w.ignoresMouseEvents && w.level == .floating)
    #expect(!w.canBecomeKey && !w.canBecomeMain)
}

@MainActor @Test func testWindowIsMarkedRed() {
    let w = CaptureTestWindow(below: .zero)
    #expect(w.contentView?.layer?.borderWidth == 4)
    #expect(w.warningLabel.stringValue == "VISIBLE TO RECORDING" && !w.warningLabel.isHidden)
}

@MainActor @Test func testWindowShowsOnlyFixedTestText() {
    let w = CaptureTestWindow(below: .zero)
    #expect(
        w.textLabel.stringValue
            == "TEST — this red box SHOULD appear in your recording. Your notes (above) should not."
    )
    #expect(w.textLabel.stringValue != NotesPanel.sampleText)
}
