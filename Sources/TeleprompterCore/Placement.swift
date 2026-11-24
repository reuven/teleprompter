import CoreGraphics

/// A platform-neutral snapshot of one display, so placement logic can be tested
/// without AppKit. The app layer converts each `NSScreen` into one of these.
public struct ScreenInfo: Sendable, Equatable {
    /// The full display rectangle in global coordinates.
    public let frame: CGRect
    /// The area not covered by the menu bar or Dock.
    public let visibleFrame: CGRect
    /// Whether this is the Mac's built-in display (the one with the camera).
    public let isBuiltIn: Bool

    /// Creates a screen snapshot.
    public init(frame: CGRect, visibleFrame: CGRect, isBuiltIn: Bool) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isBuiltIn = isBuiltIn
    }
}

/// Pure geometry for where the notes window goes, kept free of AppKit so it can
/// be tested exhaustively. Uses macOS coordinates (origin bottom-left).
public enum Placement {
    /// The notes window's size when there is no remembered frame.
    public static let defaultSize = CGSize(width: 640, height: 200)

    /// The smallest the notes window may be (its content size; the panel is borderless). Below
    /// this, the 20-point padding leaves almost no room for text and the window is easy to lose.
    public static let minimumSize = CGSize(width: 200, height: 80)

    /// Gap between the top of the visible area and the window, clearing the
    /// menu bar and notch.
    private static let topMargin: CGFloat = 8

    /// Picks the screen the camera is on, so notes sit near the lens. Falls
    /// back to the first screen (callers pass the main screen first).
    public static func cameraScreen(_ screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first(where: \.isBuiltIn) ?? screens.first
    }

    /// The default window frame: centered horizontally in the visible area,
    /// just under the top edge, which puts the text right below the camera.
    public static func defaultFrame(on screen: ScreenInfo) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(
            x: v.midX - defaultSize.width / 2,
            y: v.maxY - topMargin - defaultSize.height,
            width: defaultSize.width, height: defaultSize.height)
    }

    /// Returns the remembered frame only if it is still usable: at least half
    /// its area lies within one screen's visible frame. This guards against a
    /// disconnected display stranding the window off-screen. Corrupt frames
    /// (non-finite or empty) yield nil, since stored settings are not validated.
    ///
    /// A frame smaller than `minimumSize` is grown to it, keeping its top-left corner, before
    /// the on-screen check. Clamped rather than rejected: the window's minimum size stops the
    /// user making it that small, so such a frame came from an edited or older settings file,
    /// and its position is still the best guess at where the user wants the notes (the top
    /// edge is what sits under the camera).
    public static func restoredFrame(saved: CGRect?, screens: [ScreenInfo]) -> CGRect? {
        guard let raw = saved,
            [raw.origin.x, raw.origin.y, raw.size.width, raw.size.height].allSatisfy(
                \.isFinite),
            // `size` is the raw value; `width`/`height` would hide a negative one.
            raw.size.width > 0, raw.size.height > 0
        else { return nil }
        let width = max(raw.size.width, minimumSize.width)
        let height = max(raw.size.height, minimumSize.height)
        let saved = CGRect(x: raw.minX, y: raw.maxY - height, width: width, height: height)
        let area = saved.width * saved.height
        let onScreen = screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(saved)
            return !overlap.isNull && overlap.width * overlap.height >= 0.5 * area
        }
        return onScreen ? saved : nil
    }
}
