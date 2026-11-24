import AppKit

/// How the edit-mode editor draws the raw Markdown source.
///
/// Why a fixed size, not shrink-to-fit: while typing, text that resizes under the cursor is
/// disorienting, and the editor scrolls anyway. Sixty percent of the user's size keeps the
/// source compact enough to see its structure, with an 18 pt floor so it stays readable.
public enum EditorStyle {
    /// Smallest editor size, in points.
    public static let minFontSize: Double = 18
    /// Editor size as a fraction of the user's (recording) font size.
    public static let scale: Double = 0.6

    /// The editor's point size for a user font size of `maxFontSize`:
    /// `max(18, maxFontSize × 0.6)`.
    public static func fontSize(forMaxFontSize maxFontSize: Double) -> Double {
        max(minFontSize, maxFontSize * scale)
    }

    /// The editor's font: monospaced, because Markdown source is aligned by its markers
    /// (list indents, table pipes) and a proportional font hides that structure.
    public static func font(forMaxFontSize maxFontSize: Double) -> NSFont {
        .monospacedSystemFont(ofSize: fontSize(forMaxFontSize: maxFontSize), weight: .regular)
    }
}

/// What recording mode draws: the notes rendered at the largest size that fits, and whether
/// to show the "more below" badge.
///
/// Why a separate value: it holds every recording-mode decision (fit from the user's
/// maximum, never from the current size; render at the fitted size; badge exactly when even
/// the floor overflows) in one pure, testable place, so the view only copies it to screen.
/// Fitting always starts from `maxFontSize`, so text grows back when the window grows.
@MainActor
public struct RecordingLayout {
    /// The badge shown when notes don't fit even at `Settings.minFontSize`.
    public static let moreBelowText = "▼ more below"

    /// The rendered notes, ready to put in a text view.
    public let text: NSAttributedString
    /// The body size the notes were rendered at.
    public let fontSize: Double
    /// True when the notes overflow at the floor size, so the badge must be shown.
    public let showsMoreBelow: Bool

    /// Fits `markdown` into `contentSize` (the drawable area, insets already removed) starting
    /// from `maxFontSize`, and renders it at the chosen size.
    public init(_ markdown: String, maxFontSize: Double, in contentSize: CGSize) {
        let fit = TextFitter.fit(markdown, maxFontSize: maxFontSize, in: contentSize)
        text = MarkdownRenderer.render(markdown, style: NoteStyle(fontSize: fit.fontSize))
        fontSize = fit.fontSize
        showsMoreBelow = fit.overflows
    }
}
