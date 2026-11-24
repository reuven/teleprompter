import AppKit
import TeleprompterCore

/// The floating notes window that sits under the camera and stays out of screen recordings.
///
/// Why a custom `NSPanel`: the whole app depends on this one window being readable on screen yet
/// absent from ScreenFlow, never stealing focus from the app being recorded, and following the user
/// across Spaces and full-screen apps. Every one of those properties is fixed here, in one place,
/// so the tests can pin them without a visible window.
final class NotesPanel: NSPanel {
    /// The text shown until notes files arrive (Task 7); it tells the user how to check hiding.
    static let sampleText = """
        Teleprompter — sample notes
        • This window should NOT appear in your recording
        • Menu-bar icon › Show in Recordings (Test) makes it visible
        """

    /// Corner radius of the dark background, in points.
    static let cornerRadius: CGFloat = 16
    /// Gap between the background edge and the text, in points.
    static let padding: CGFloat = 20
    /// Width of the red "visible to recording" border, in points.
    static let captureBorderWidth: CGFloat = 4

    /// Edit takes clicks and focus; recording lets every click pass through to the app beneath,
    /// so reading notes can never disturb the app being recorded.
    var mode: Mode = .recording {
        didSet { ignoresMouseEvents = (mode == .recording) }
    }

    /// The background's opacity, taken from settings; exposed so tests can check it.
    private(set) var backgroundAlpha: Double

    /// The rounded dark view behind the text; it also carries the capture-check border.
    let backgroundView = NSView()
    /// The notes text.
    let textLabel: NSTextField
    /// Shown only while the window is deliberately visible to capture, so a test recording can't
    /// be confused with a real one.
    let captureLabel = NSTextField(labelWithString: "VISIBLE TO RECORDING")

    /// Builds the panel with the exact window configuration the hiding depends on.
    ///
    /// The frame is a default-sized placeholder; the app delegate positions the panel, so this
    /// stays free of screen lookups and can be built in tests.
    init(settings: Settings) {
        backgroundAlpha = settings.opacity
        textLabel = NSTextField(wrappingLabelWithString: Self.sampleText)
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
        buildContent(fontSize: settings.fontSize)
    }

    /// Only edit mode may take keyboard focus; borderless panels refuse it by default.
    override var canBecomeKey: Bool { mode == .edit }

    /// Never main: the panel is an accessory and must not demote the app being recorded.
    override var canBecomeMain: Bool { false }

    /// Turns the "check capture" opt-in on or off: makes the window recordable and marks it with a
    /// red border and label so it is unmistakable on screen and in the recording.
    func setCaptureVisible(_ on: Bool) {
        sharingType = on ? .readOnly : .none
        backgroundView.layer?.borderWidth = on ? Self.captureBorderWidth : 0
        captureLabel.isHidden = !on
    }

    /// Brings the panel in line with `state`, the single source of truth for mode and capture.
    ///
    /// Why one entry point: a mode change must also clear the capture check and move focus, and
    /// doing all three together means no caller can leave the panel half-switched (for example,
    /// recordable after locking for recording). Entering edit takes key focus so typing reaches
    /// the panel; leaving it drops first responder and key status so keystrokes return to the
    /// app being recorded.
    func apply(_ state: ModeState) {
        let entering = state.mode != mode
        mode = state.mode
        setCaptureVisible(state.captureVisible)
        guard entering else { return }
        if mode == .edit {
            makeKey()
        } else {
            makeFirstResponder(nil)
            resignKey()
        }
    }

    private func buildContent(fontSize: Double) {
        backgroundView.wantsLayer = true
        let layer = backgroundView.layer
        layer?.backgroundColor = NSColor.black.withAlphaComponent(backgroundAlpha).cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.systemRed.cgColor
        layer?.borderWidth = 0
        contentView = backgroundView

        textLabel.textColor = .white
        textLabel.font = .systemFont(ofSize: fontSize)
        captureLabel.textColor = .systemRed
        captureLabel.font = .boldSystemFont(ofSize: 12)
        captureLabel.isHidden = true

        for view in [textLabel, captureLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backgroundView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor, constant: Self.padding),
            textLabel.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor, constant: -Self.padding),
            textLabel.topAnchor.constraint(
                equalTo: backgroundView.topAnchor, constant: Self.padding),
            captureLabel.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor, constant: -Self.padding),
            captureLabel.bottomAnchor.constraint(
                equalTo: backgroundView.bottomAnchor, constant: -Self.padding / 2),
        ])
    }
}
