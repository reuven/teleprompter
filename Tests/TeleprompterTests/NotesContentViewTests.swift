import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// The content view is the only place the user's notes reach the screen. These pin the two modes'
// behavior without a visible window: raw, plain-text editing; rendered, fitted reading with an
// honest "more below" badge; and drawing in exactly the box that was measured.

private let frame = CGRect(x: 0, y: 0, width: 600, height: 180)
private let longNotes = (1...200).map { "- bullet \($0)" }.joined(separator: "\n")
private let mediumNotes = (1...8).map { "- point number \($0)" }.joined(separator: "\n")

/// Each test gets its own temporary folder for scratch notes and files, deleted afterwards, so
/// tests never touch the user's notes and leave nothing behind.
@MainActor @Suite final class NotesContentViewTests {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "NotesContentViewTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A store on this test's scratch file, starting with `text`.
    func makeStore(_ text: String = "") -> NotesStore {
        let url = dir.appending(path: "scratch.md")
        if !text.isEmpty { try? Data(text.utf8).write(to: url) }
        return NotesStore(scratchURL: url, saveDelay: .milliseconds(1))
    }

    // MARK: Edit mode

    @Test func editModeShowsRawTextInTheEditorOnly() {
        let v = NotesContentView(
            store: makeStore("# Title"), maxFontSize: 40, mode: .edit, frame: frame)
        #expect(v.editor.string == "# Title")
        #expect(!v.editorScrollView.isHidden && v.reader.isHidden && v.badge.isHidden)
        #expect(v.editor.isEditable && v.editor.isSelectable)
    }

    @Test func editorUsesFixedMonospacedSize() {
        let v = NotesContentView(store: makeStore("x"), maxFontSize: 40, mode: .edit, frame: frame)
        #expect(v.editor.font == EditorStyle.font(forMaxFontSize: 40))
        // No shrink-to-fit while typing: lots of text keeps the same size.
        v.editor.string = longNotes
        v.editor.didChangeText()
        #expect(v.editor.font?.pointSize == 24)
    }

    @Test func editorIsPlainTextWithNoSubstitutions() {
        let e = NotesContentView(store: makeStore(), maxFontSize: 32, mode: .edit, frame: frame)
            .editor
        #expect(!e.isRichText && !e.importsGraphics && e.allowsUndo)
        #expect(!e.isAutomaticQuoteSubstitutionEnabled && !e.isAutomaticDashSubstitutionEnabled)
        #expect(!e.isAutomaticTextReplacementEnabled && !e.isAutomaticSpellingCorrectionEnabled)
        #expect(!e.isAutomaticLinkDetectionEnabled && !e.isAutomaticDataDetectionEnabled)
        #expect(!e.isAutomaticTextCompletionEnabled && !e.smartInsertDeleteEnabled)
    }

    // The editor must not open system windows that quote the notes (Look Up, Services, Writing Tools,
    // spelling or completion popups): those are other processes' or unshielded windows and could be
    // recorded.

    @Test func editorHasNoSpellingGrammarOrWritingTools() {
        let e = NotesContentView(store: makeStore(), maxFontSize: 32, mode: .edit, frame: frame)
            .editor
        #expect(type(of: e) == NotesEditor.self && e.enclosingScrollView != nil)
        #expect(!e.isContinuousSpellCheckingEnabled && !e.isGrammarCheckingEnabled)
        #expect(e.writingToolsBehavior == .none)
    }

    @Test func editorContextMenuOffersOnlyClipboardEditing() throws {
        let e = NotesContentView(store: makeStore("x"), maxFontSize: 32, mode: .edit, frame: frame)
            .editor
        let click = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(e.menu(for: click))
        #expect(menu.items.map(\.title) == ["Cut", "Copy", "Paste", "Select All"])
        #expect(
            menu.items.map(\.action)
                == [
                    #selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                    #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
                ])
        #expect(!menu.allowsContextMenuPlugIns && !menu.automaticallyInsertsWritingToolsItems)
    }

    @Test func editorCompletionAndLookUpDoNothing() throws {
        let store = makeStore("hel")
        let e = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame).editor
        e.setSelectedRange(NSRange(location: 3, length: 0))
        e.complete(nil)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        e.quickLook(with: click)
        #expect(e.string == "hel" && store.text == "hel")
    }

    @Test func typingGoesToTheStore() {
        let store = makeStore()
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        v.editor.string = "- new"
        v.editor.didChangeText()
        #expect(store.text == "- new")
    }

    @Test func externalChangeReplacesEditorTextKeepingSelection() {
        let store = makeStore("hello world")
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        v.editor.setSelectedRange(NSRange(location: 6, length: 5))
        // Stands in for a reload; the view hears about it via notesChanged().
        store.userEdited("hello there")
        v.notesChanged()
        #expect(v.editor.string == "hello there")
        #expect(v.editor.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func externalChangeClampsSelectionToShorterText() {
        let store = makeStore("hello world")
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        v.editor.setSelectedRange(NSRange(location: 8, length: 3))
        store.userEdited("hi")
        v.notesChanged()
        #expect(
            v.editor.string == "hi" && v.editor.selectedRange() == NSRange(location: 2, length: 0))
    }

    // The clamp itself, without relying on NSTextView also snapping selections (it does today, but
    // that isn't documented).
    @Test func clampKeepsRangesThatStillFit() {
        #expect(
            NotesContentView.clampedSelection([NSRange(location: 1, length: 2)], to: "hello")
                == [NSRange(location: 1, length: 2)])
    }

    @Test func clampShortensRangesPastTheEnd() {
        #expect(
            NotesContentView.clampedSelection([NSRange(location: 3, length: 9)], to: "hello")
                == [NSRange(location: 3, length: 2)])
        #expect(
            NotesContentView.clampedSelection([NSRange(location: 8, length: 3)], to: "hi")
                == [NSRange(location: 2, length: 0)])
    }

    @Test func clampWidensToWholeEmojiAndSnapsCaretsToTheirStart() {
        // "a😀😀" is 5 UTF-16 units: a, then surrogate pairs at 1–2 and 3–4.
        #expect(
            NotesContentView.clampedSelection([NSRange(location: 2, length: 2)], to: "a😀😀")
                == [NSRange(location: 1, length: 4)])
        #expect(
            NotesContentView.clampedSelection([NSRange(location: 2, length: 0)], to: "a😀")
                == [NSRange(location: 1, length: 0)])
        // A family emoji is one character of 11 units; a caret inside it moves to its start.
        #expect(
            NotesContentView.clampedSelection([NSRange(location: 5, length: 0)], to: "x👨‍👩‍👧‍👦")
                == [NSRange(location: 1, length: 0)])
    }

    @Test func clampedSelectionNeverSplitsAnEmoji() {
        // "a😀😀" is 5 UTF-16 units: a, then two surrogate pairs at 1–2 and 3–4.
        let store = makeStore("abcdef")
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        // In the new text, 2..<4 would cover half of each emoji.
        v.editor.setSelectedRange(NSRange(location: 2, length: 2))
        store.userEdited("a😀😀")
        v.notesChanged()
        #expect(v.editor.selectedRange() == NSRange(location: 1, length: 4))
    }

    @Test func clampedCaretNeverLandsInsideAnEmoji() {
        let store = makeStore("abc")
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        // Offset 2 would sit between the halves of a surrogate pair in the new text.
        v.editor.setSelectedRange(NSRange(location: 2, length: 0))
        store.userEdited("a😀")
        v.notesChanged()
        #expect(v.editor.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func unchangedTextLeavesTheEditorAlone() {
        let store = makeStore("same")
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        v.editor.setSelectedRange(NSRange(location: 1, length: 2))
        v.notesChanged()
        #expect(v.editor.selectedRange() == NSRange(location: 1, length: 2))
    }

    @Test func externalChangeClearsUndoSoItCantReplayStaleEdits() throws {
        // Undo history describes edits to the old text; replaying it on the reloaded text would apply
        // them at the wrong places. In a window, so the editor has an undo manager.
        let store = makeStore("abc")
        let v = NotesContentView(store: store, maxFontSize: 32, mode: .edit, frame: frame)
        let panel = NotesPanel(settings: Settings(), content: v)
        let undo = try #require(v.editor.undoManager)
        v.editor.setSelectedRange(NSRange(location: 3, length: 0))
        v.editor.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        v.editor.breakUndoCoalescing()
        #expect(undo.canUndo && store.text == "abcd")
        store.userEdited("reloaded")
        v.notesChanged()
        #expect(!undo.canUndo && v.editor.string == "reloaded")
        withExtendedLifetime(panel) {}
    }

    @Test func reallyExternalChangeReachesTheView() async throws {
        // End to end: another program writes the open file; the store reloads and the view follows.
        let file = dir.appending(path: "talk.md")
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

    @Test func recordingModeShowsRenderedNotesOnly() {
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

    @Test func fitIsMeasuredInExactlyTheDrawableBox() {
        let v = NotesContentView(
            store: makeStore(mediumNotes), maxFontSize: 60, mode: .recording, frame: frame)
        // Zero insets and padding, so the drawable box is the reader's bounds, and that is what fit got.
        #expect(v.reader.textContainerInset == .zero)
        #expect(v.reader.textContainer?.lineFragmentPadding == 0)
        #expect(v.drawableSize == v.reader.bounds.size && v.drawableSize == frame.size)
        #expect(v.fittedSize == v.drawableSize)
        #expect(v.reader.textContainer?.size.width == v.drawableSize.width)
    }

    @Test func drawnTextFitsWhereMeasurementSaidItWould() throws {
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

    @Test func richMarkdownAlsoFitsWhereMeasurementSaidItWould() throws {
        // Every construct whose layout could differ between measuring and drawing: a heading,
        // bullets long enough to wrap, a numbered list, a nested list, and a code block.
        let notes = """
            # Talk outline

            - A bullet long enough that it has to wrap onto a second line in a narrow panel
            - Short one

            1. First numbered point, also long enough to wrap around at narrow widths
            2. Second

            - Outer item
              - Nested item that is fairly long and wraps under its own hanging indent
                - Deeper still

            ```
            let code = "monospaced block"
            ```
            """
        var checked = 0
        for width in [320.0, 480.0, 700.0] {
            for height in stride(from: 300.0, through: 900.0, by: 150.0) {
                let box = CGRect(x: 0, y: 0, width: width, height: height)
                let v = NotesContentView(
                    store: makeStore(notes), maxFontSize: 60, mode: .recording, frame: box)
                guard v.badge.isHidden else { continue }  // overflowing fits are clipped on purpose
                let layout = try #require(v.reader.layoutManager)
                let container = try #require(v.reader.textContainer)
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container)
                #expect(used.height.rounded(.up) <= box.height && used.width <= box.width)
                checked += 1
            }
        }
        #expect(checked >= 10)  // most boxes must fit, or the loop proves nothing
    }

    @Test func shrinkingTheViewShrinksTheTextThenShowsTheBadge() throws {
        let v = NotesContentView(
            store: makeStore(mediumNotes), maxFontSize: 60,
            mode: .recording, frame: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(v.fittedFontSize == 60 && v.badge.isHidden)
        v.setFrameSize(frame.size)
        #expect(try #require(v.fittedFontSize) < 60)
        #expect(v.badge.isHidden && v.fittedSize == frame.size)
        v.setFrameSize(CGSize(width: 200, height: 40))
        #expect(v.fittedFontSize == Settings.minFontSize && !v.badge.isHidden)
        #expect(v.badge.stringValue == "▼ more below")
    }

    @Test func growingTheViewGrowsTheTextBack() throws {
        let v = NotesContentView(
            store: makeStore(mediumNotes), maxFontSize: 60, mode: .recording, frame: frame)
        #expect(try #require(v.fittedFontSize) < 60)
        v.setFrameSize(CGSize(width: 1600, height: 1200))
        #expect(v.fittedFontSize == 60)
    }

    @Test func overflowingNotesShowTheBadgeAtTheBottomEdge() {
        let v = NotesContentView(
            store: makeStore(longNotes), maxFontSize: 40, mode: .recording, frame: frame)
        v.layoutSubtreeIfNeeded()
        #expect(!v.badge.isHidden && v.badge.frame.minY == 0)
        #expect(abs(v.badge.frame.midX - frame.midX) < 1)
    }

    @Test func changingTheMaximumRefitsAndResizesTheEditor() {
        let v = NotesContentView(
            store: makeStore("Hi"), maxFontSize: 40, mode: .recording, frame: frame)
        v.maxFontSize = 50
        #expect(v.fittedFontSize == 50 && v.editor.font?.pointSize == 30)
    }

    // MARK: Switching modes

    @Test func switchingToRecordingRendersWhatWasTyped() {
        let v = NotesContentView(store: makeStore(), maxFontSize: 40, mode: .edit, frame: frame)
        #expect(v.fittedSize == nil)  // nothing is fitted while editing
        v.editor.string = "# Typed"
        v.editor.didChangeText()
        v.mode = .recording
        #expect(v.reader.string == "Typed" && v.editorScrollView.isHidden && !v.reader.isHidden)
    }

    @Test func editingHidesTheBadge() {
        let v = NotesContentView(
            store: makeStore(longNotes), maxFontSize: 40, mode: .recording, frame: frame)
        #expect(!v.badge.isHidden)
        v.mode = .edit
        #expect(v.badge.isHidden && v.reader.isHidden && !v.editorScrollView.isHidden)
        v.mode = .recording
        #expect(!v.badge.isHidden)
    }

    @Test func enteringEditFocusesTheEditor() {
        let store = makeStore("notes")
        let v = NotesContentView(store: store, maxFontSize: 40, mode: .recording, frame: frame)
        let panel = NotesPanel(settings: Settings(), content: v)
        panel.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var state = ModeState.initial(hasNotes: true)
        state.toggleMode()
        panel.apply(state, takeFocus: true)
        v.mode = .edit
        #expect(panel.firstResponder === v.editor)
    }
}
