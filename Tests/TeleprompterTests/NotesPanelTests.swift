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

/// A ⌘-key event as the panel would receive it.
@MainActor private func key(_ chars: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
        keyCode: 0)!
}

@MainActor @Test func textSizeKeysAreCommandPlusAndMinusOnly() {
    #expect(NotesPanel.textSizeStep(for: key("=")) == 1)
    #expect(NotesPanel.textSizeStep(for: key("+", [.command, .shift])) == 1)
    #expect(NotesPanel.textSizeStep(for: key("+", [.command, .numericPad])) == 1)
    #expect(NotesPanel.textSizeStep(for: key("-")) == -1)
    #expect(NotesPanel.textSizeStep(for: key("-", [.command, .numericPad])) == -1)
    #expect(NotesPanel.textSizeStep(for: key("-", [])) == nil, "plain minus is typing")
    #expect(NotesPanel.textSizeStep(for: key("=", [.command, .option])) == nil)
    #expect(NotesPanel.textSizeStep(for: key("-", [.command, .control])) == nil)
    #expect(NotesPanel.textSizeStep(for: key("c")) == nil)
}

@MainActor @Test func commandPlusAndMinusStepTextSizeInEditModeOnly() {
    let p = NotesPanel(settings: Settings())
    var steps: [Int] = []
    p.onTextSizeStep = { steps.append($0) }
    p.mode = .edit
    #expect(p.performKeyEquivalent(with: key("=")))
    #expect(p.performKeyEquivalent(with: key("-")))
    #expect(!p.performKeyEquivalent(with: key("c")))
    p.mode = .recording
    #expect(!p.performKeyEquivalent(with: key("=")))
    #expect(steps == [1, -1])
}

@MainActor @Test func opacityChangesTheBackgroundButNeverTheHiding() {
    let p = NotesPanel(settings: Settings(opacity: 0.85))
    p.setOpacity(0.5)
    #expect(p.backgroundAlpha == 0.5)
    #expect(p.backgroundView.layer?.backgroundColor?.alpha == 0.5)
    #expect(p.sharingType == .none)
}

/// Records the editing actions that reach it through the responder chain.
@MainActor private final class EditSpy: NSView {
    var received: [String] = []
    override var acceptsFirstResponder: Bool { true }
    @objc func cut(_ sender: Any?) { received.append("cut:") }
    @objc func copy(_ sender: Any?) { received.append("copy:") }
    @objc func paste(_ sender: Any?) { received.append("paste:") }
    @objc override func selectAll(_ sender: Any?) { received.append("selectAll:") }
    @objc func undo(_ sender: Any?) { received.append("undo:") }
    @objc func redo(_ sender: Any?) { received.append("redo:") }
}

@MainActor @Test func editingShortcutsReachTheFocusedViewInEditModeOnly() {
    let spy = EditSpy()
    let p = NotesPanel(settings: Settings(), content: spy)
    p.mode = .edit
    #expect(p.makeFirstResponder(spy))
    for chars in ["x", "c", "v", "a", "z"] {
        #expect(p.performKeyEquivalent(with: key(chars)), "⌘\(chars)")
    }
    #expect(p.performKeyEquivalent(with: key("Z", [.command, .shift])), "⌘⇧Z")
    #expect(spy.received == ["cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:"])

    // Option or Control turn them into other shortcuts; recording mode handles none.
    #expect(!p.performKeyEquivalent(with: key("c", [.command, .option])))
    #expect(!p.performKeyEquivalent(with: key("v", [.command, .control])))
    p.mode = .recording
    for chars in ["x", "c", "v", "a", "z"] {
        #expect(!p.performKeyEquivalent(with: key(chars)), "⌘\(chars) in recording")
    }
    #expect(spy.received.count == 6)
}

@MainActor @Test func editingShortcutNobodyHandlesIsNotSwallowed() {
    let p = NotesPanel(settings: Settings(), content: NSView())
    p.mode = .edit
    p.makeFirstResponder(nil)
    #expect(!p.performKeyEquivalent(with: key("x")), "nothing can cut: left to AppKit")
}

@MainActor @Test func editingShortcutsWorkOnTheRealEditor() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "PanelEdit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = NotesStore(scratchURL: dir.appending(path: "scratch.md"), saveDelay: .seconds(30))
    let content = NotesContentView(
        store: store, maxFontSize: 32, mode: .edit,
        frame: CGRect(x: 0, y: 0, width: 600, height: 180))
    let p = NotesPanel(settings: Settings(), content: content)
    p.mode = .edit
    #expect(p.makeFirstResponder(content.editor))
    // Explicit grouping: event-based grouping would leave a run-loop observer behind that
    // closes the group later, inside whichever test spins the run loop next.
    let undo = try #require(content.editor.undoManager)
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    content.editor.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
    undo.endUndoGrouping()
    #expect(p.performKeyEquivalent(with: key("a")))
    #expect(content.editor.selectedRange() == NSRange(location: 0, length: 5))
    #expect(p.performKeyEquivalent(with: key("z")))
    #expect(content.editor.string.isEmpty, "⌘Z undid the typing")
    #expect(p.performKeyEquivalent(with: key("Z", [.command, .shift])))
    #expect(content.editor.string == "hello", "⌘⇧Z redid it")
}

@MainActor @Test func editingActionTable() {
    #expect(NotesPanel.editingAction(for: key("c")) == #selector(NSText.copy(_:)))
    #expect(NotesPanel.editingAction(for: key("Z", [.command, .shift])) == #selector(EditSpy.redo(_:)))
    #expect(NotesPanel.editingAction(for: key("c", [.command, .shift])) == nil)
    #expect(NotesPanel.editingAction(for: key("q")) == nil)
    #expect(NotesPanel.editingAction(for: key("c", [])) == nil)
}
