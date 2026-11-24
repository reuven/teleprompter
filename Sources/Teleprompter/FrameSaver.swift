/// Saves the notes panel's frame once a move or resize has settled, and ignores moves the
/// system makes when the displays change.
///
/// Why: saving on every intermediate move event is wasteful, and saving a frame macOS chose
/// after a display was unplugged would overwrite where the user put the panel, so it wouldn't
/// come back there when the display returns. The system's move can arrive just before or just
/// after the display-change notification, so a display change also cancels a pending save.
@MainActor
final class FrameSaver {
    /// How long the frame must stay still before it's saved.
    let delay: Duration
    /// How long after a display change moves are ignored.
    let quietAfterScreenChange: Duration
    private let save: () -> Void
    private var task: Task<Void, Never>?
    private var screensChangedAt: ContinuousClock.Instant?

    /// `save` writes the current frame; it's called on the main actor.
    init(delay: Duration, quietAfterScreenChange: Duration, save: @escaping () -> Void) {
        self.delay = delay
        self.quietAfterScreenChange = quietAfterScreenChange
        self.save = save
    }

    /// Whether a save is waiting for the frame to settle.
    var isPending: Bool { task != nil }

    /// Call on every move or resize: (re)starts the wait, unless the displays just changed.
    func frameChanged() {
        if let changed = screensChangedAt, ContinuousClock.now - changed < quietAfterScreenChange {
            return
        }
        task?.cancel()
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Call when the display configuration changes: drops a pending save and starts the quiet
    /// period.
    func screenParametersChanged() {
        screensChangedAt = ContinuousClock.now
        task?.cancel()
        task = nil
    }

    /// Saves now if a save is pending (on quit, so a move just before Quit isn't lost); does
    /// nothing otherwise, so an untouched launch position is never saved as the user's choice.
    func flush() {
        guard let pending = task else { return }
        pending.cancel()
        task = nil
        save()
    }
}
