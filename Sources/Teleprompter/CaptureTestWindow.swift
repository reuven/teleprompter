import AppKit
import TeleprompterCore

/// A deliberately recordable copy of the notes, shown by Show in Recordings (Test).
///
/// Why a separate window: the notes panel must never have its `sharingType` changed (on macOS
/// 26.5, setting it back to `.none` is silently ignored for LaunchServices-launched apps). This
/// window is the positive control instead: in a test recording the red copy should appear and the
/// notes panel above it should not. A new one is created each time the test is turned on and
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

    /// Builds the window at the panel's size, placed directly below `panelFrame` so both are on
    /// screen at once. Uses default styling; only the frame comes from the panel.
    init(below panelFrame: CGRect) {
        let (background, label) = NotesPanel.makeContent(text: Self.text, settings: Settings())
        textLabel = label
        super.init(
            contentRect: Self.frame(below: panelFrame),
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

    /// The frame with `panelFrame`'s size and left edge, `gap` points below it.
    static func frame(below panelFrame: CGRect) -> CGRect {
        CGRect(
            x: panelFrame.minX, y: panelFrame.minY - gap - panelFrame.height,
            width: panelFrame.width, height: panelFrame.height)
    }
}
