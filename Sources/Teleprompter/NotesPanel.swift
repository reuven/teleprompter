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
    /// The text shown until notes files arrive (Task 7); it tells the user how to check hiding.
    static let sampleText = """
        Teleprompter — sample notes
        • This window should NOT appear in your recording
        • Menu-bar icon › Show in Recordings (Test) shows a red test box that SHOULD appear
        """

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

    /// The rounded dark view behind the text.
    let backgroundView: NSView
    /// The notes text.
    let textLabel: NSTextField

    /// Builds the panel with the exact window configuration the hiding depends on.
    ///
    /// The frame is a default-sized placeholder; the app delegate positions the panel, so this
    /// stays free of screen lookups and can be built in tests.
    init(settings: Settings) {
        backgroundAlpha = settings.opacity
        (backgroundView, textLabel) = Self.makeContent(text: Self.sampleText, settings: settings)
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
    }

    /// Only edit mode may take keyboard focus; borderless panels refuse it by default.
    override var canBecomeKey: Bool { mode == .edit }

    /// Never main: the panel is an accessory and must not demote the app being recorded.
    override var canBecomeMain: Bool { false }

    /// Brings the panel in line with `state`'s mode, moving focus with it.
    ///
    /// Why one entry point: a mode change must also move focus, and doing both together means no
    /// caller can leave the panel half-switched. Entering edit takes key focus so typing reaches
    /// the panel; leaving it drops first responder and really gives up key status by ordering
    /// the panel out and straight back in (`resignKey()` is a notification hook, documented as not
    /// to be called directly, and AppKit doesn't recheck `canBecomeKey` when it turns false).
    /// Capture visibility is deliberately not applied here (see the type docs).
    func apply(_ state: ModeState) {
        let entering = state.mode != mode
        mode = state.mode
        guard entering else { return }
        if mode == .edit {
            makeKey()
        } else {
            makeFirstResponder(nil)
            if isVisible {
                orderOut(nil)
                orderFrontRegardless()
            }
        }
    }

    /// Builds the rounded dark background with `text` inset by `padding`.
    ///
    /// Shared with `CaptureTestWindow` so the positive control is styled like the notes; callers
    /// choose the text, which is how the test window is kept from ever showing the notes.
    static func makeContent(text: String, settings: Settings) -> (NSView, NSTextField) {
        let background = NSView()
        background.wantsLayer = true
        let layer = background.layer
        layer?.backgroundColor = NSColor.black.withAlphaComponent(settings.opacity).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

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
