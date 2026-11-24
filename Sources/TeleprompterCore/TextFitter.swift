import AppKit

/// The outcome of a shrink-to-fit pass.
public struct FitResult: Sendable, Equatable {
    /// Chosen body size in whole points.
    public let fontSize: Double
    /// True when the notes do not fit even at the floor size, so the UI must show a
    /// "more below" marker rather than silently cutting text off.
    public let overflows: Bool

    /// Creates a result; used by the fitter and by tests.
    public init(fontSize: Double, overflows: Bool) {
        self.fontSize = fontSize
        self.overflows = overflows
    }
}

/// Chooses the font size at which notes fit the window.
///
/// The user's font size is a maximum, not a promise: text silently cut off mid-recording
/// is the worst failure for this tool, so we shrink (down to `Settings.minFontSize`) and
/// report honestly when even that is not enough.
public enum TextFitter {
    /// Returns the largest whole-point size in `minFontSize...maxFontSize` at which
    /// `markdown` fits in `size`, the drawable content area (callers subtract insets).
    ///
    /// Use it whenever notes or the window change. The binary search only ever moves its
    /// lower bound to a size that was measured to fit, so a fitting result is real even if
    /// line wrapping makes height non-monotonic in size. Heights are rounded up so
    /// sub-point rounding cannot claim a fit that clips. A non-finite or non-positive
    /// maximum is treated as the floor; a degenerate box overflows (unless the notes are
    /// empty, which always fit).
    public static func fit(_ markdown: String, maxFontSize: Double, in size: CGSize) -> FitResult {
        let floor = Settings.minFontSize
        let top =
            maxFontSize.isFinite && maxFontSize > 0
            ? max(floor, min(maxFontSize, Settings.maxFontSize).rounded(.down))
            : floor
        if markdown.isEmpty { return FitResult(fontSize: top, overflows: false) }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return FitResult(fontSize: floor, overflows: true)
        }

        func fits(_ points: Double) -> Bool {
            MarkdownRenderer.render(markdown, style: NoteStyle(fontSize: points))
                .boundingRect(
                    with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height.rounded(.up) <= size.height
        }

        var low = Int(floor)
        var high = Int(top)
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(Double(mid)) { low = mid } else { high = mid - 1 }
        }
        return FitResult(fontSize: Double(low), overflows: !fits(Double(low)))
    }
}
