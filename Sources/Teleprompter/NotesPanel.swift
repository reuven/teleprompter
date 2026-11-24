import AppKit
import TeleprompterCore

/// The floating notes window that sits under the camera and stays out of screen recordings.
///
/// Why a custom `NSPanel`: the whole app depends on this one window being readable on screen yet
/// absent from ScreenFlow, never stealing focus from the app being recorded, and following the user
/// across Spaces and full-screen apps. Every one of those properties is fixed here, in one place,
/// so the tests can pin them without a visible window.
///
/// `sharingType` is set to `.none` once, in `init`, and never written again. On macOS 26.5 a
/// LaunchServices-launched app that sets a window back to `.none` after making it recordable is
/// silently ignored (the window stays recordable while AppKit's getter still says `.none`), so the
/// capture test uses a separate `CaptureTestWindow` instead of toggling this one.
final class NotesPanel: NSPanel {
    /// Corner radius of the dark background, in points.
    static let cornerRadius: CGFloat = 16
    /// Gap between the background edge and the text, in points.
    static let padding: CGFloat = 20

    /// Edit takes clicks and focus; recording lets every click pass through to the app beneath,
    /// so reading notes can never disturb the app being recorded.
    var mode: Mode = .recording {
        didSet { ignoresMouseEvents = (mode == .recording) }
    }

    /// The background's opacity, taken from settings; exposed so tests can check it.
    private(set) var backgroundAlpha: Double

    /// Called with +1 or −1 when ⌘+ or ⌘− is pressed while the panel is key (edit mode). The app
    /// delegate routes it to the same path as Larger/Smaller Text, which also works from the menu
    /// in either mode. Needed because a menu-bar app has no main menu to carry these shortcuts.
    var onTextSizeStep: ((Int) -> Void)?

    /// The rounded dark view behind the notes.
    let backgroundView: NSView
    /// What the panel shows: the notes view in the app, inset by `padding` and resized with the
    /// panel.
    let content: NSView

    /// Builds the panel with the exact window configuration the hiding depends on, showing
    /// `content` (in the app, a `NotesContentView`).
    ///
    /// The frame is a default-sized placeholder; the app delegate positions the panel, so this
    /// stays free of screen lookups and can be built in tests.
    init(settings: Settings, content: NSView = NSView()) {
        backgroundAlpha = settings.opacity
        backgroundView = Self.makeBackground(settings: settings)
        self.content = content
        super.init(
            contentRect: CGRect(origin: .zero, size: Placement.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        sharingType = .none
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = (mode == .recording)
        contentView = backgroundView
        content.frame = backgroundView.bounds.insetBy(dx: Self.padding, dy: Self.padding)
        content.autoresizingMask = [.width, .height]
        backgroundView.addSubview(content)
    }

    /// Only edit mode may take keyboard focus; borderless panels refuse it by default.
    override var canBecomeKey: Bool { mode == .edit }

    /// Never main: the panel is an accessory and must not demote the app being recorded.
    override var canBecomeMain: Bool { false }

    /// Handles, in edit mode only, ⌘+ / ⌘− (see `onTextSizeStep`) and the editing shortcuts
    /// (see `editingAction`), which go up the responder chain from the focused view (the
    /// editor) as the Edit menu would send them. An editing shortcut nobody handles, and
    /// everything else, goes to AppKit.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if mode == .edit {
            if let step = Self.textSizeStep(for: event) {
                onTextSizeStep?(step)
                return true
            }
            // This panel's own chain, from its focused view: `NSApp.sendAction(_:to: nil, …)`
            // would pick the app's key window, which need not be this panel.
            // (A window's first responder is the window itself when no view has focus.)
            if let action = Self.editingAction(for: event), let responder = firstResponder,
                responder.tryToPerform(action, with: self)
            {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The editing action for ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z (Command alone) or ⌘⇧Z, or nil.
    ///
    /// Why the panel maps these itself: these shortcuts normally come from the main menu's Edit
    /// menu, but the app deliberately has no main menu, because AppKit adds Writing Tools,
    /// Dictation and Emoji & Symbols to an Edit menu, and those open out-of-process windows
    /// that quote the notes.
    static func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "x"): return #selector(NSText.cut(_:))
        case (.command, "c"): return #selector(NSText.copy(_:))
        case (.command, "v"): return #selector(NSText.paste(_:))
        case (.command, "a"): return #selector(NSText.selectAll(_:))
        case (.command, "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }

    /// +1 for ⌘= / ⌘+ (main keyboard or keypad), −1 for ⌘−, nil for anything else. Shift is
    /// allowed (⌘+ is ⌘⇧= on most layouts); Option and Control are not, so other shortcuts are
    /// left alone.
    static func textSizeStep(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case "=", "+": return 1
        case "-": return -1
        default: return nil
        }
    }

    /// Changes the background's opacity (Opacity menu) without rebuilding the panel. Only the
    /// background color changes; the window's capture setting is never touched here.
    func setOpacity(_ opacity: Double) {
        backgroundAlpha = opacity
        backgroundView.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(opacity).cgColor
    }

    /// Brings the panel in line with `state`'s mode, moving focus with it.
    ///
    /// Why one entry point: a mode change must also move focus, and doing both together means no
    /// caller can leave the panel half-switched. Entering edit takes key focus so typing reaches
    /// the panel; leaving it drops first responder and really gives up key status by ordering
    /// the panel out and straight back in (`resignKey()` is a notification hook, documented as not
    /// to be called directly, and AppKit doesn't recheck `canBecomeKey` when it turns false).
    /// Capture visibility is deliberately not applied here (see the type docs).
    ///
    /// `takeFocus` has no default, so every caller decides: `false` at launch (an empty-notes
    /// launch starts in edit mode, clickable, but must not take keystrokes from the frontmost
    /// app; a click on the panel gives it focus), `true` for the user's own toggles.
    func apply(_ state: ModeState, takeFocus: Bool) {
        let entering = state.mode != mode
        mode = state.mode
        guard entering else { return }
        if mode == .edit {
            if takeFocus { makeKey() }
        } else {
            makeFirstResponder(nil)
            if isVisible {
                orderOut(nil)
                orderFrontRegardless()
            }
        }
    }

    /// The rounded dark background, at `settings`' opacity, shared by the notes panel and the
    /// capture test window so the positive control looks like the thing it checks.
    static func makeBackground(settings: Settings) -> NSView {
        let background = NSView()
        background.wantsLayer = true
        let layer = background.layer
        layer?.backgroundColor = NSColor.black.withAlphaComponent(settings.opacity).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        return background
    }

    /// Builds the rounded dark background with `text` inset by `padding`.
    ///
    /// Used only by `CaptureTestWindow`, which passes its fixed test text: that is how the
    /// recordable test window is kept from ever showing the notes.
    static func makeContent(text: String, settings: Settings) -> (NSView, NSTextField) {
        let background = makeBackground(settings: settings)

        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .white
        label.font = .systemFont(ofSize: settings.fontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: padding),
        ])
        return (background, label)
    }
}
