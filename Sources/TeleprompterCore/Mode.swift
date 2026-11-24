/// The two states of the notes window: editing the text, or showing it for reading while recording.
///
/// Kept as a plain value type in the core module so the mode rules can be tested without AppKit.
public enum Mode: Sendable, Equatable {
    case edit
    case recording
}

/// The window's mode plus whether the window is deliberately visible to screen capture.
///
/// This exists to enforce one safety rule in one place: capture visibility is an explicit,
/// temporary opt-in (for checking the window), so it can never survive a mode change or be on at
/// launch.
public struct ModeState: Sendable, Equatable {
    public private(set) var mode: Mode
    public private(set) var captureVisible: Bool

    /// Builds the launch state: recording when notes exist (ready to read), edit when empty.
    /// Capture visibility always starts off so a fresh launch never leaks into a recording.
    public static func initial(hasNotes: Bool) -> ModeState {
        ModeState(mode: hasNotes ? .recording : .edit, captureVisible: false)
    }

    /// Flips between edit and recording, and always turns capture visibility off.
    public mutating func toggleMode() {
        mode = (mode == .edit) ? .recording : .edit
        captureVisible = false
    }

    /// Sets whether the window may be seen by screen capture (the "check capture" opt-in).
    public mutating func setCaptureVisible(_ visible: Bool) {
        captureVisible = visible
    }
}
