import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// The content view is the only place the user's notes reach the screen. These pin the two modes'
// behavior without a visible window: raw, plain-text editing; rendered, fitted reading with an
// honest "more below" badge; and drawing in exactly the box that was measured.

/// A store on a fresh temporary scratch file, so tests never touch the user's notes.
@MainActor private func makeStore(_ text: String = "") -> NotesStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesContentViewTests-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("scratch.md")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !text.isEmpty { try? Data(text.utf8).write(to: url) }
    return NotesStore(scratchURL: url, saveDelay: .milliseconds(1))
}

private let frame = CGRect(x: 0, y: 0, width: 600, height: 180)
private let longNotes = (1...200).map { "- bullet \($0)" }.joined(separator: "\n")
private let mediumNotes = (1...8).map { "- point number \($0)" }.joined(separator: "\n")

// MARK: Edit mode

@MainActor @Test func editModeShowsRawTextInTheEditorOnly() {
    let v = NotesContentView(
        store: makeStore("# Title"), maxFontSize: 40, mode: .edit, frame: frame)
    #expect(v.editor.string == "# Title")
    #expect(!v.editorScrollView.isHidden && v.reader.isHidden && v.badge.isHidden)
    #expect(v.editor.isEditable && v.editor.isSelectable)
}

@MainActor @Test func editorUsesFixedMonospacedSize() {
    let v = NotesContentView(store: makeStore("x"), maxFontSize: 40, mode: .edit, frame: frame)
    #expect(v.editor.font == EditorStyle.font(forMaxFontSize: 40))
    // No shrink-to-fit while typing: lots of text keeps the same size.
    v.editor.string = longNotes
    v.editor.didChangeText()
    #expect(v.editor.font?.pointSize == 24)
}

@MainActor @Test func editorIsPlainTextWithNoSubstitutions() {
    let e = NotesContentView(store: makeStore(), maxFontSize: 32, mode: .edit, frame: frame).editor
    #expect(!e.isRichText && !e.importsGraphics && e.allowsUndo)
    #expect(!e.isAutomaticQuoteSubstitutionEnabled && !e.isAutomaticDashSubstitutionEnabled)
    #expect(!e.isAutomaticTextReplacementEnabled && !e.isAutomaticSpellingCorrectionEnabled)
    #expect(!e.isAutomaticLinkDetectionEnabled && !e.isAutomaticDataDetectionEnabled)
    #expect(!e.isAutomaticTextCompletionEnabled && !e.smartInsertDeleteEnabled)
}

@MainActor @Test func typingGoesToTheStore() {
    let store = makeStore()
    let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
    v.editor.string = "- new"
    v.editor.didChangeText()
    #expect(store.text == "- new")
}

@MainActor @Test func externalChangeReplacesEditorTextKeepingSelection() {
    let store = makeStore("hello world")
    let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
    v.editor.setSelectedRange(NSRange(location: 6, length: 5))
    store.userEdited("hello there")  // stands in for a reload; the view hears via notesChanged()
    v.notesChanged()
    #expect(v.editor.string == "hello there")
    #expect(v.editor.selectedRange() == NSRange(location: 6, length: 5))
}

@MainActor @Test func externalChangeClampsSelectionToShorterText() {
    let store = makeStore("hello world")
    let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
    v.editor.setSelectedRange(NSRange(location: 8, length: 3))
    store.userEdited("hi")
    v.notesChanged()
    #expect(v.editor.string == "hi" && v.editor.selectedRange() == NSRange(location: 2, length: 0))
}

@MainActor @Test func unchangedTextLeavesTheEditorAlone() {
    let store = makeStore("same")
    let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
    v.editor.setSelectedRange(NSRange(location: 1, length: 2))
    v.editor.undoManager?.removeAllActions()
    v.notesChanged()
    #expect(v.editor.selectedRange() == NSRange(location: 1, length: 2))
}

@MainActor @Test func reallyExternalChangeReachesTheView() async throws {
    // End to end: another program writes the open file; the store reloads and the view follows.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesContentViewTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("talk.md")
    try Data("# Before".utf8).write(to: file)
    let store = makeStore()
    store.open(file)
    let v = NotesContentView(store: store, maxFontSize: 32, mode: .recording, frame: frame)
    store.onExternalChange = { v.notesChanged() }
    try Data("# After".utf8).write(to: file, options: .atomic)
    for _ in 0..<200 where v.reader.string != "After" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(v.reader.string == "After" && v.editor.string == "# After")
}

// MARK: Recording mode

@MainActor @Test func recordingModeShowsRenderedNotesOnly() {
    let v = NotesContentView(
        store: makeStore("# Hi\n\n- one"), maxFontSize: 40, mode: .recording, frame: frame)
    #expect(v.editorScrollView.isHidden && !v.reader.isHidden && v.badge.isHidden)
    let expected = RecordingLayout("# Hi\n\n- one", maxFontSize: 40, in: v.drawableSize)
    // Same text and fonts; not isEqual, because the text storage normalizes each paragraph to its
    // first character's paragraph style (TextKit's attribute fixing), as drawing does.
    let shown = v.reader.attributedString()
    #expect(shown.string == expected.text.string)
    for index in [0, shown.length - 1] {
        #expect(
            shown.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                == expected.text.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }
    #expect(!v.reader.isEditable && !v.reader.isSelectable && !v.reader.drawsBackground)
}

@MainActor @Test func fitIsMeasuredInExactlyTheDrawableBox() {
    let v = NotesContentView(
        store: makeStore(mediumNotes), maxFontSize: 60, mode: .recording, frame: frame)
    // Zero insets and padding, so the drawable box is the reader's bounds, and that is what fit got.
    #expect(v.reader.textContainerInset == .zero)
    #expect(v.reader.textContainer?.lineFragmentPadding == 0)
    #expect(v.drawableSize == v.reader.bounds.size && v.drawableSize == frame.size)
    #expect(v.fittedSize == v.drawableSize)
    #expect(v.reader.textContainer?.size.width == v.drawableSize.width)
}

@MainActor @Test func drawnTextFitsWhereMeasurementSaidItWould() throws {
    // The reader lays text out exactly as the fitter measured it: what fits on paper fits on screen.
    for height in stride(from: 200.0, through: 480.0, by: 35.0) {
        let box = CGRect(x: 0, y: 0, width: 500, height: height)
        let v = NotesContentView(
            store: makeStore(mediumNotes), maxFontSize: 60, mode: .recording, frame: box)
        try #require(v.badge.isHidden)
        let layout = try #require(v.reader.layoutManager)
        let container = try #require(v.reader.textContainer)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        #expect(used.height.rounded(.up) <= box.height && used.width <= box.width)
    }
}

@MainActor @Test func shrinkingTheViewShrinksTheTextThenShowsTheBadge() {
    let v = NotesContentView(
        store: makeStore(mediumNotes), maxFontSize: 60,
        mode: .recording, frame: CGRect(x: 0, y: 0, width: 1600, height: 1200))
    #expect(v.fittedFontSize == 60 && v.badge.isHidden)
    v.setFrameSize(frame.size)
    #expect(v.fittedFontSize! < 60 && v.badge.isHidden && v.fittedSize == frame.size)
    v.setFrameSize(CGSize(width: 200, height: 40))
    #expect(v.fittedFontSize == Settings.minFontSize && !v.badge.isHidden)
    #expect(v.badge.stringValue == "▼ more below")
}

@MainActor @Test func growingTheViewGrowsTheTextBack() {
    let v = NotesContentView(
        store: makeStore(mediumNotes), maxFontSize: 60, mode: .recording, frame: frame)
    #expect(v.fittedFontSize! < 60)
    v.setFrameSize(CGSize(width: 1600, height: 1200))
    #expect(v.fittedFontSize == 60)
}

@MainActor @Test func overflowingNotesShowTheBadgeAtTheBottomEdge() {
    let v = NotesContentView(
        store: makeStore(longNotes), maxFontSize: 40, mode: .recording, frame: frame)
    v.layoutSubtreeIfNeeded()
    #expect(!v.badge.isHidden && v.badge.frame.minY == 0)
    #expect(abs(v.badge.frame.midX - frame.midX) < 1)
}

@MainActor @Test func changingTheMaximumRefitsAndResizesTheEditor() {
    let v = NotesContentView(
        store: makeStore("Hi"), maxFontSize: 40, mode: .recording, frame: frame)
    v.maxFontSize = 50
    #expect(v.fittedFontSize == 50 && v.editor.font?.pointSize == 30)
}

// MARK: Switching modes

@MainActor @Test func switchingToRecordingRendersWhatWasTyped() {
    let v = NotesContentView(store: makeStore(), maxFontSize: 40, mode: .edit, frame: frame)
    #expect(v.fittedSize == nil)  // nothing is fitted while editing
    v.editor.string = "# Typed"
    v.editor.didChangeText()
    v.mode = .recording
    #expect(v.reader.string == "Typed" && v.editorScrollView.isHidden && !v.reader.isHidden)
}

@MainActor @Test func editingHidesTheBadge() {
    let v = NotesContentView(
        store: makeStore(longNotes), maxFontSize: 40, mode: .recording, frame: frame)
    #expect(!v.badge.isHidden)
    v.mode = .edit
    #expect(v.badge.isHidden && v.reader.isHidden && !v.editorScrollView.isHidden)
    v.mode = .recording
    #expect(!v.badge.isHidden)
}

@MainActor @Test func enteringEditFocusesTheEditor() {
    let store = makeStore("notes")
    let v = NotesContentView(store: store, maxFontSize: 40, mode: .recording, frame: frame)
    let panel = NotesPanel(settings: Settings(), content: v)
    panel.setFrameOrigin(CGPoint(x: -20000, y: -20000))
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    var state = ModeState.initial(hasNotes: true)
    state.toggleMode()
    panel.apply(state)
    v.mode = .edit
    #expect(panel.firstResponder === v.editor)
}
