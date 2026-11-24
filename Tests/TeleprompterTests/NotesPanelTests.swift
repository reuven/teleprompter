import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// These pin the anti-goals: the panel must stay out of screen recordings, and in recording mode
// it must never take clicks or focus. None of them needs a visible window.

@MainActor @Test func newPanelIsHiddenFromCapture() {
    #expect(NotesPanel(settings: Settings()).sharingType == .none)
}

@MainActor @Test func recordingModeIgnoresClicksAndFocus() {
    let p = NotesPanel(settings: Settings())
    p.mode = .recording
    #expect(p.ignoresMouseEvents && !p.canBecomeKey && !p.canBecomeMain)
}

@MainActor @Test func editModeAcceptsClicksAndFocus() {
    let p = NotesPanel(settings: Settings())
    p.mode = .edit
    #expect(!p.ignoresMouseEvents && p.canBecomeKey)
}

@MainActor @Test func panelIsNonActivatingAndOnAllSpaces() {
    let p = NotesPanel(settings: Settings())
    #expect(p.styleMask.contains(.nonactivatingPanel))
    #expect(
        p.collectionBehavior.contains(.canJoinAllSpaces)
            && p.collectionBehavior.contains(.fullScreenAuxiliary))
}

@MainActor @Test func opacityFromSettings() {
    #expect(NotesPanel(settings: Settings(opacity: 0.5)).backgroundAlpha == 0.5)
}

@MainActor @Test func panelFloatsAndStaysPut() {
    let p = NotesPanel(settings: Settings())
    #expect(p.level == .floating && !p.hidesOnDeactivate && p.isMovableByWindowBackground)
    #expect(p.collectionBehavior.contains(.stationary) && !p.canBecomeMain)
    #expect(p.styleMask.contains(.borderless) && p.styleMask.contains(.resizable))
}

@MainActor @Test func showsItsContentInsetByPaddingAndResizesIt() {
    let content = NSView()
    let p = NotesPanel(settings: Settings(), content: content)
    #expect(content.superview === p.backgroundView && p.content === content)
    #expect(content.frame == p.backgroundView.bounds.insetBy(dx: 20, dy: 20))
    p.setContentSize(CGSize(width: 800, height: 300))
    #expect(content.frame == CGRect(x: 20, y: 20, width: 760, height: 260))
}

@MainActor @Test func lockingReallyGivesUpKeyStatus() {
    // On screen (far off to the side) so the panel can genuinely become key; the first expectation
    // proves it did, so the second can't pass vacuously.
    let p = NotesPanel(settings: Settings())
    p.setFrameOrigin(CGPoint(x: -20000, y: -20000))
    p.orderFrontRegardless()
    defer { p.orderOut(nil) }
    var state = ModeState.initial(hasNotes: false)
    state.toggleMode()
    p.apply(state, takeFocus: true)  // recording
    state.toggleMode()
    p.apply(state, takeFocus: true)  // edit
    #expect(p.isKeyWindow)
    state.toggleMode()
    p.apply(state, takeFocus: true)  // recording
    #expect(!p.isKeyWindow && p.isVisible)
    #expect(p.mode == .recording && p.ignoresMouseEvents && p.firstResponder === p)
}

@MainActor @Test func modeMenuTitleOffersTheOtherMode() {
    #expect(StatusMenu.modeTitle(for: .recording) == "Edit Notes")
    #expect(StatusMenu.modeTitle(for: .edit) == "Lock for Recording")
}

@MainActor @Test func applyingEditStateAcceptsInput() {
    let p = NotesPanel(settings: Settings())
    var state = ModeState.initial(hasNotes: true)
    p.apply(state, takeFocus: true)
    #expect(p.mode == .recording && p.ignoresMouseEvents)
    state.toggleMode()
    p.apply(state, takeFocus: true)
    #expect(p.mode == .edit && !p.ignoresMouseEvents && p.canBecomeKey)
}

/// Guards against app code writing `sharingType` on a mode switch. It cannot catch the macOS 26.5
/// behavior where a LaunchServices-launched app's return to `.none` is ignored (this test process
/// isn't launched that way, and AppKit's getter lies there anyway); only the runtime window-server
/// self-check in `CaptureCheck.swift` covers that.
@MainActor @Test func panelStaysHiddenThroughModeSwitches() {
    let p = NotesPanel(settings: Settings())
    var state = ModeState.initial(hasNotes: true)
    for _ in 0..<4 {
        state.setCaptureVisible(true)
        p.apply(state, takeFocus: true)
        #expect(p.sharingType == .none)
        state.toggleMode()
        p.apply(state, takeFocus: true)
        #expect(p.sharingType == .none)
    }
}

/// Launching with empty notes starts in edit mode, but launching must never take keystrokes from
/// the frontmost app: the panel is clickable but not key until the user clicks it.
@MainActor @Test func launchApplyInEditModeDoesNotTakeFocus() throws {
    let content = NotesContentView(
        store: NotesStore(
            scratchURL: FileManager.default.temporaryDirectory.appending(
                path: "launch-\(UUID().uuidString)/scratch.md")),
        maxFontSize: 32, mode: .edit, frame: .zero)
    let p = NotesPanel(settings: Settings(), content: content)
    p.setFrameOrigin(CGPoint(x: -20000, y: -20000))
    p.orderFrontRegardless()
    defer { p.orderOut(nil) }
    let state = ModeState.initial(hasNotes: false)
    try #require(state.mode == .edit)
    p.apply(state, takeFocus: false)
    content.mode = state.mode
    #expect(p.mode == .edit && !p.ignoresMouseEvents && p.canBecomeKey)
    #expect(!p.isKeyWindow)
    // Control: the same panel does become key when focus is wanted, so the check above isn't
    // vacuous.
    var toggled = state
    toggled.toggleMode()
    p.apply(toggled, takeFocus: true)
    toggled.toggleMode()
    p.apply(toggled, takeFocus: true)
    #expect(p.isKeyWindow)
}
