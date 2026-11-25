import AppKit
import TeleprompterCore

/// The notes themselves, inside the panel: an editor for the Markdown source in edit mode, and the
/// rendered notes, shrunk to fit, in recording mode.
///
/// Why one view with two children: the panel's frame, background and hiding never change with
/// the mode, only what is drawn inside it, so switching is just showing one child and hiding the
/// other. Every recording-mode decision comes from `RecordingLayout`; this view only copies the
/// result to screen and decides *when* to refit (on resize, text, or maximum-size changes).
///
/// The reader is laid out with no inset and no line-fragment padding, so the box measured by
/// the fitter is exactly the box the text is drawn in; otherwise "fits" could still clip.
@MainActor
final class NotesContentView: NSView, NSTextViewDelegate {
    /// The model: the editor writes to it, and both children show its text.
    let store: NotesStore
    /// Edit mode's text view, raw Markdown in a fixed-size monospaced font.
    let editor: NotesEditor
    /// Scrolls the editor; long notes scroll rather than shrink while typing.
    let editorScrollView: NSScrollView
    /// Recording mode's view: the rendered notes, not editable or selectable.
    let reader: NSTextView
    // The reader's TextKit 1 stack, built by hand so the container is never optional and the
    // storage (which owns the layout manager) is kept alive by this view.
    private let readerStorage = NSTextStorage()
    private let readerContainer = NSTextContainer()
    /// "▼ more below", pinned to the bottom edge when notes overflow even at the floor size.
    let badge = NSTextField(labelWithString: RecordingLayout.moreBelowText)
    /// The recording timer, in a strip at the bottom; hidden until `showTimer` gives it text.
    let timerLabel = NSTextField(labelWithString: "")
    /// Whether the timer strip is showing, so the notes sit above it.
    private var showsTimer = false
    /// The badge's distance from the bottom: above the strip while the timer shows.
    private var badgeBottom: NSLayoutConstraint?

    /// The size passed to the fitter by the last fit, or nil if nothing has been fitted yet.
    private(set) var fittedSize: CGSize?
    /// The font size chosen by the last fit, or nil if nothing has been fitted yet.
    private(set) var fittedFontSize: Double?
    // What the last fit was computed from; a fit is redone only when one of these changes.
    private var fittedText: String?
    private var fittedMax: Double?
    // Whether the last fit overflowed; kept so returning to recording restores the badge.
    private var fittedOverflows = false

    /// The user's font size: the editor is sized from it and every fit starts from it, so changing
    /// it (Larger/Smaller Text) refits at once.
    var maxFontSize: Double {
        didSet {
            editor.font = EditorStyle.font(forMaxFontSize: maxFontSize)
            refit()
        }
    }

    /// Which child is shown. Entering edit focuses the editor; entering recording refits, so what
    /// was just typed is what is shown.
    var mode: Mode {
        didSet { showMode() }
    }

    /// Builds both children around `store`'s current text and shows the one for `mode`.
    init(store: NotesStore, maxFontSize: Double, mode: Mode, frame: CGRect) {
        self.store = store
        self.maxFontSize = maxFontSize
        self.mode = mode
        editorScrollView = NotesEditor.scrollableTextView()
        // scrollableTextView() builds a text view of the class it's called on.
        editor = editorScrollView.documentView as! NotesEditor
        let layoutManager = NSLayoutManager()
        readerStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(readerContainer)
        reader = NSTextView(frame: .zero, textContainer: readerContainer)
        super.init(frame: frame)

        configureEditor()
        configureReader()
        configureBadge()
        configureTimerLabel()
        layoutNotes()
        showMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The box the reader draws text in: its bounds minus the container inset and line-fragment
    /// padding (both zero, but subtracted anyway so the two can't drift apart).
    var drawableSize: CGSize {
        let inset = reader.textContainerInset
        let padding = readerContainer.lineFragmentPadding
        return CGSize(
            width: reader.bounds.width - 2 * inset.width - 2 * padding,
            height: reader.bounds.height - 2 * inset.height)
    }

    /// Refits after a resize: the window got bigger or smaller, so the best size changed too.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutNotes()
        refit()
    }

    /// Shows `text` in the timer strip, colored by `level`, or hides the strip when `text` is nil.
    /// Showing or hiding it moves the notes and refits them; updating the text alone doesn't.
    func showTimer(_ text: String?, level: TimerLevel) {
        timerLabel.stringValue = text ?? ""
        timerLabel.textColor = Self.color(for: level)
        let shows = text != nil
        timerLabel.isHidden = !shows
        guard shows != showsTimer else { return }
        showsTimer = shows
        badgeBottom?.constant = shows ? -TimerStrip.height : 0
        layoutNotes()
        refit()
    }

    /// White normally, amber near the target, red past it (on the panel's dark background).
    static func color(for level: TimerLevel) -> NSColor {
        switch level {
        case .normal: .white
        case .warning: .systemOrange
        case .over: .systemRed
        }
    }

    /// Puts the editor and the reader in the notes area: the whole view, or the part above the
    /// timer strip.
    private func layoutNotes() {
        let notes = TimerStrip.notesFrame(in: bounds, showsTimer: showsTimer)
        editorScrollView.frame = notes
        reader.frame = notes
    }

    /// Call when the store's text changed from outside the app (another editor saved the file):
    /// re-renders at once in either mode, and updates the editor only if its text differs, keeping
    /// the selection where the text still allows it and clearing undo.
    func notesChanged() {
        if editor.string != store.text {
            let selection = Self.clampedSelection(
                editor.selectedRanges.map(\.rangeValue), to: store.text)
            editor.string = store.text
            editor.selectedRanges = selection.map { NSValue(range: $0) }
            // The undo history describes edits to the old text; replaying it on the new text
            // would apply them in the wrong places, so it goes.
            editor.undoManager?.removeAllActions()
        }
        refit()
    }

    /// Fits selection `ranges` from the old text into `text`: each is cut off at the end and widened
    /// to whole characters (a range never splits an emoji or other multi-unit character), and a
    /// caret inside a character moves to its start.
    ///
    /// Why: after another program changes the file, the old selection may point past the end or
    /// into the middle of a surrogate pair, and typing there would corrupt the character.
    static func clampedSelection(_ ranges: [NSRange], to text: String) -> [NSRange] {
        let ns = text as NSString
        return ranges.map { range in
            let start = min(range.location, ns.length)
            let clamped = NSRange(location: start, length: min(range.length, ns.length - start))
            guard clamped.length == 0 else {
                return ns.rangeOfComposedCharacterSequences(for: clamped)
            }
            guard start < ns.length else { return clamped }
            return NSRange(
                location: ns.rangeOfComposedCharacterSequence(at: start).location, length: 0)
        }
    }

    /// Sends each edit to the store, which saves it after a short pause.
    func textDidChange(_ notification: Notification) {
        store.userEdited(editor.string)
    }

    private func configureEditor() {
        editorScrollView.drawsBackground = false
        editorScrollView.hasVerticalScroller = true
        editorScrollView.scrollerStyle = .overlay
        editor.delegate = self
        // Markdown source: no styling, and none of the substitutions that would corrupt it.
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        // No checking UI: suggestions and Writing Tools open windows that quote the notes.
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.writingToolsBehavior = .none
        editor.drawsBackground = false
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.font = EditorStyle.font(forMaxFontSize: maxFontSize)
        editor.string = store.text
        addSubview(editorScrollView)
    }

    private func configureReader() {
        reader.isEditable = false
        reader.isSelectable = false
        reader.drawsBackground = false
        // A fixed-size view: the default (grow to fit the text) would make the measured box and
        // the drawn box differ.
        reader.isVerticallyResizable = false
        reader.isHorizontallyResizable = false
        reader.textContainerInset = .zero
        readerContainer.lineFragmentPadding = 0
        // Width follows the view; height is unlimited so layout never stops early. The view clips
        // what doesn't fit, and the badge says so.
        readerContainer.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        readerContainer.widthTracksTextView = true
        addSubview(reader)
    }

    private func configureBadge() {
        badge.font = .boldSystemFont(ofSize: 13)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        let bottom = badge.bottomAnchor.constraint(equalTo: bottomAnchor)
        badgeBottom = bottom
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor), bottom,
        ])
    }

    /// A fixed, readable size whatever the notes shrink to, with digits of equal width so the
    /// time doesn't wobble as it counts.
    private func configureTimerLabel() {
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        timerLabel.alignment = .right
        timerLabel.isHidden = true
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timerLabel)
        NSLayoutConstraint.activate([
            timerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timerLabel.centerYAnchor.constraint(
                equalTo: bottomAnchor, constant: -TimerStrip.height / 2),
        ])
    }

    private func showMode() {
        let editing = mode == .edit
        editorScrollView.isHidden = !editing
        reader.isHidden = editing
        if editing {
            badge.isHidden = true
            window?.makeFirstResponder(editor)
        } else {
            refit()
            badge.isHidden = !fittedOverflows
        }
    }

    /// Fits and renders the notes for the reader, from `maxFontSize` every time (never from the
    /// last fitted size), so text grows back as well as shrinks. Does nothing while editing, and
    /// skips the work when nothing it depends on has changed.
    private func refit() {
        guard mode == .recording else { return }
        let size = drawableSize
        let text = store.text
        guard size != fittedSize || text != fittedText || maxFontSize != fittedMax else { return }
        let layout = RecordingLayout(text, maxFontSize: maxFontSize, in: size)
        readerStorage.setAttributedString(layout.text)
        (fittedSize, fittedText, fittedMax) = (size, text, maxFontSize)
        fittedFontSize = layout.fontSize
        fittedOverflows = layout.showsMoreBelow
        badge.isHidden = !layout.showsMoreBelow
    }
}

/// The edit-mode text view, with every feature that would show the notes in another window
/// switched off.
///
/// Why: the notes panel is hidden from capture, but Look Up popovers, Services, Writing Tools,
/// spelling suggestions and completion lists are separate windows (some in other processes, out
/// of `CaptureShield`'s reach) that quote the text, so they could appear in a recording. The
/// context menu keeps only Cut, Copy, Paste and Select All; completion and every Look Up entry
/// point (force click, three-finger tap, ⌃⌘D) do nothing.
final class NotesEditor: NSTextView {
    /// Only clipboard editing; no Look Up, Search, Services, Writing Tools or spelling items.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.automaticallyInsertsWritingToolsItems = false
        for (title, action) in [
            ("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))),
            ("Paste", #selector(NSText.paste(_:))), ("Select All", #selector(NSText.selectAll(_:))),
        ] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        return menu
    }

    /// No completion list (⌥⎋ / F5): it's a separate window listing words from the notes.
    override func complete(_ sender: Any?) {}

    /// No Look Up (force click, three-finger tap): its popover quotes the selected text.
    override func quickLook(with event: NSEvent) {}

    /// No Look Up via ⌃⌘D or the Services path: it opens a highlight overlay window here and an
    /// out-of-process popover showing a word of the notes.
    override func showDefinition(
        for attrString: NSAttributedString?, at textBaselineOrigin: NSPoint
    ) {}

    /// No Look Up for a range either (the form the text system itself uses).
    override func showDefinition(
        for attrString: NSAttributedString?, range targetRange: NSRange,
        options: [NSView.DefinitionOptionKey: Any]? = nil,
        baselineOriginProvider originProvider: ((NSRange) -> NSPoint)? = nil
    ) {}
}
