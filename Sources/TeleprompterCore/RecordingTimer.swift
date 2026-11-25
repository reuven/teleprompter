import CoreGraphics

/// The recording timer's state: hidden until first used, then running or stopped.
///
/// Why one key cycles start → stop → restart: during a take the moments that matter are "I'm
/// starting", "how long was that?" (the stopped time stays on screen) and "again from the top".
/// Times are instants handed in by the caller, so tests control the clock and the app can use
/// `ContinuousClock`, which never jumps when the system time changes.
public struct RecordingTimer: Equatable, Sendable {
    /// Where the timer is in its cycle.
    public enum Phase: Equatable, Sendable {
        /// Not shown; the panel looks as it does without a timer.
        case hidden
        /// Counting up from `since`.
        case running(since: ContinuousClock.Instant)
        /// Stopped, showing the take's length until the next press or hide.
        case stopped(elapsed: Duration)
    }

    /// The current phase; changed only by `press` and `hide`.
    public private(set) var phase: Phase = .hidden

    /// Creates a hidden timer.
    public init() {}

    /// The shortcut's action: hidden or stopped → start from zero; running → stop and keep
    /// the time.
    public mutating func press(at now: ContinuousClock.Instant) {
        if case .running = phase {
            phase = .stopped(elapsed: elapsed(at: now))
        } else {
            phase = .running(since: now)
        }
    }

    /// Puts the timer away (Hide Timer); the next press starts from zero.
    public mutating func hide() {
        phase = .hidden
    }

    /// Time on the clock at `now`: zero while hidden, frozen while stopped, never negative.
    public func elapsed(at now: ContinuousClock.Instant) -> Duration {
        switch phase {
        case .hidden: .zero
        case .running(let since): max(.zero, now - since)
        case .stopped(let elapsed): elapsed
        }
    }

    /// Whether the panel shows the timer strip.
    public var isVisible: Bool { phase != .hidden }

    /// Whether the time is advancing (the app refreshes the display only then).
    public var isRunning: Bool {
        if case .running = phase { true } else { false }
    }
}

/// How urgent the time looks: normal, then amber in the last seconds before the target, then
/// red once it's reached.
public enum TimerLevel: Equatable, Sendable {
    case normal, warning, over
}

/// The timer's text and color level, from the elapsed time and the optional target.
///
/// Both use whole seconds (rounded down), so the color changes exactly when the number does.
public enum TimerDisplay {
    /// Seconds before the target when the time turns amber.
    public static let warningLead = 5

    /// `m:ss` under an hour (`0:42`, `10:00`), `h:mm:ss` from an hour on (`1:02:03`).
    public static func format(seconds: Int) -> String {
        let (hours, minutes, secs) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        let mmss = "\(twoDigits(minutes)):\(twoDigits(secs))"
        if hours > 0 { return "\(hours):\(mmss)" }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// The strip's text: `0:42`, or `0:42 / 1:00` with a target.
    public static func text(elapsed: Duration, target: Int?) -> String {
        let shown = format(seconds: wholeSeconds(elapsed))
        guard let target else { return shown }
        return "\(shown) / \(format(seconds: target))"
    }

    /// Normal until `warningLead` seconds before the target, warning until the target, then
    /// over. Always normal without a target.
    public static func level(elapsed: Duration, target: Int?) -> TimerLevel {
        guard let target else { return .normal }
        let seconds = wholeSeconds(elapsed)
        if seconds >= target { return .over }
        return seconds >= target - warningLead ? .warning : .normal
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// The strip at the bottom of the notes panel that holds the timer.
///
/// Why a fixed strip, not text in the notes: the notes re-fit only when the strip appears or
/// disappears, never every second, and the timer stays the same size however small the notes get.
public enum TimerStrip {
    /// The strip's height, in points.
    public static let height: CGFloat = 30

    /// Where the notes go inside `bounds` (AppKit coordinates, y up): all of it, or everything
    /// above the strip while the timer shows. Never a negative height.
    public static func notesFrame(in bounds: CGRect, showsTimer: Bool) -> CGRect {
        guard showsTimer else { return bounds }
        let strip = min(height, bounds.size.height)
        return CGRect(
            x: bounds.minX, y: bounds.minY + strip, width: bounds.size.width,
            height: bounds.size.height - strip)
    }
}
