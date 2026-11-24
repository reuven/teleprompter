import AppKit
import TeleprompterCore

/// A deliberately recordable, fixed-text positive control, shown by Show in Recordings (Test).
///
/// Why a separate window: the notes panel must never have its `sharingType` changed (on macOS
/// 26.5, setting it back to `.none` is silently ignored for LaunchServices-launched apps). This
/// window is the positive control instead: in a test recording the red test box should appear
/// and the notes panel next to it should not. A new one is created each time the test is turned on and
/// closed when it is turned off, so a recordable window is never reused or left behind.
///
/// It is recordable by design, so it must never show the user's notes: it takes only a frame and
/// always shows the fixed `text`.
final class CaptureTestWindow: NSPanel {
    /// Vertical gap between the notes panel and this window, in points.
    static let gap: CGFloat = 8
    /// The only text this window ever shows.
    static let text =
        "TEST — this red box SHOULD appear in your recording. Your notes (above) should not."
    /// Width of the red border, in points.
    static let borderWidth: CGFloat = 4

    /// Shows `text`, never the notes.
    let textLabel: NSTextField
    /// Says plainly that this window is recordable, on screen and in the recording.
    let warningLabel = NSTextField(labelWithString: "VISIBLE TO RECORDING")

    /// Builds the window at the panel's size, next to `panelFrame` inside `visibleFrame` (the
    /// panel's screen) so both are on screen at once. Uses default styling; only the frame comes
    /// from the panel.
    init(near panelFrame: CGRect, within visibleFrame: CGRect) {
        let (background, label) = NotesPanel.makeContent(text: Self.text, settings: Settings())
        textLabel = label
        super.init(
            contentRect: Self.frame(near: panelFrame, within: visibleFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        sharingType = .readOnly
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        background.layer?.borderColor = NSColor.systemRed.cgColor
        background.layer?.borderWidth = Self.borderWidth
        warningLabel.textColor = .systemRed
        warningLabel.font = .boldSystemFont(ofSize: 12)
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(warningLabel)
        NSLayoutConstraint.activate([
            warningLabel.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -NotesPanel.padding),
            warningLabel.bottomAnchor.constraint(
                equalTo: background.bottomAnchor, constant: -NotesPanel.padding / 2),
        ])
        contentView = background
    }

    /// Never takes focus: it exists only to be seen.
    override var canBecomeKey: Bool { false }

    /// Never main, for the same reason as the notes panel.
    override var canBecomeMain: Bool { false }

    /// Moves the window to stay next to the panel after the panel moves or resizes, so the
    /// positive control is always beside the notes it is checking.
    func follow(_ panelFrame: CGRect, within visibleFrame: CGRect) {
        setFrame(Self.frame(near: panelFrame, within: visibleFrame), display: true)
    }

    /// The panel's size, `gap` points below it, or above it when there isn't room below; then
    /// clamped into `visibleFrame` so the control can never land off-screen and go unrecorded.
    static func frame(near panelFrame: CGRect, within visibleFrame: CGRect) -> CGRect {
        let size = panelFrame.size
        let below = panelFrame.minY - gap - size.height
        let y = below >= visibleFrame.minY ? below : panelFrame.maxY + gap
        return CGRect(
            x: min(max(panelFrame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width, height: size.height)
    }
}
