import CoreGraphics
import Foundation

/// User preferences for the notes window, validated on every construction path.
///
/// Why: settings are persisted as JSON and may be hand-edited or corrupted. Both
/// `init` and `init(from:)` run the same normalization (the Swift analogue of
/// Pydantic validators), so an invalid stored value can never crash the app or
/// put the UI in an impossible state.
public struct Settings: Codable, Sendable, Equatable {
    /// Smallest allowed font size, in points.
    public static let minFontSize: Double = 14
    /// Largest allowed font size, in points.
    public static let maxFontSize: Double = 120
    /// Default font size, also used when a stored value is NaN.
    public static let defaultFontSize: Double = 32
    /// The only opacity values the UI offers; stored values snap to the nearest.
    public static let opacityPresets: [Double] = [0.5, 0.7, 0.85, 1.0]
    /// Default opacity, also used when a stored value is NaN.
    public static let defaultOpacity: Double = 0.85
    /// Maximum number of remembered recent files.
    public static let maxRecentFiles = 5
    /// How much Larger Text / Smaller Text (and ⌘+ / ⌘−) change the font size, in points.
    public static let fontSizeStep: Double = 2

    /// Text size in points. Settable by the UI; always re-normalized so a bad write cannot stick.
    public var fontSize: Double {
        didSet { fontSize = Settings.normalizedFontSize(fontSize) }
    }
    /// Window opacity. Settable by the UI; always snapped to a preset so the menu stays truthful.
    public var opacity: Double {
        didSet { opacity = Settings.normalizedOpacity(opacity) }
    }
    /// Last window position and size, restored at launch; nil until the user has moved it.
    public var windowFrame: CGRect?
    /// File to reopen at launch; nil when nothing has been opened.
    public var lastFileURL: URL?
    /// Recently opened files for the menu, most recent first; changed only via `noteOpened`
    /// so the cap and no-duplicates rules always hold.
    public private(set) var recentFiles: [URL]

    /// Creates settings, normalizing every value so the result is always valid.
    public init(
        fontSize: Double = Settings.defaultFontSize,
        opacity: Double = Settings.defaultOpacity,
        windowFrame: CGRect? = nil,
        lastFileURL: URL? = nil,
        recentFiles: [URL] = []
    ) {
        self.fontSize = Settings.normalizedFontSize(fontSize)
        self.opacity = Settings.normalizedOpacity(opacity)
        self.windowFrame = windowFrame
        self.lastFileURL = lastFileURL
        self.recentFiles = Settings.normalizedRecents(recentFiles)
    }

    /// Decodes tolerantly: missing keys take defaults, bad values are normalized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontSize: (try? c.decodeIfPresent(Double.self, forKey: .fontSize))
                ?? Settings.defaultFontSize,
            opacity: (try? c.decodeIfPresent(Double.self, forKey: .opacity))
                ?? Settings.defaultOpacity,
            windowFrame: (try? c.decodeIfPresent(CGRect.self, forKey: .windowFrame)) ?? nil,
            lastFileURL: (try? c.decodeIfPresent(URL.self, forKey: .lastFileURL)) ?? nil,
            recentFiles: (try? c.decodeIfPresent([URL].self, forKey: .recentFiles)) ?? nil ?? []
        )
    }

    /// Records that `url` was opened: it becomes the last file and the most recent entry.
    public mutating func noteOpened(_ url: URL) {
        lastFileURL = url
        recentFiles = Settings.normalizedRecents([url] + recentFiles)
    }

    /// Changes the font size by `steps` × `fontSizeStep` (negative to shrink), clamped like any
    /// other write, so the menu and the panel's shortcuts share one rule.
    public mutating func stepFontSize(_ steps: Int) {
        fontSize += Double(steps) * Settings.fontSizeStep
    }

    /// Whether Larger Text would change anything; the menu disables the item at the maximum.
    public var canMakeTextLarger: Bool { fontSize < Settings.maxFontSize }

    /// Whether Smaller Text would change anything; the menu disables the item at the minimum.
    public var canMakeTextSmaller: Bool { fontSize > Settings.minFontSize }

    /// The file to reopen at launch: `lastFileURL` if `exists` says it's still there, else nil
    /// (scratch notes). Why a check first: a file deleted or moved while the app was closed
    /// should quietly give scratch notes, not an error on every launch.
    public func launchFile(exists: (URL) -> Bool) -> URL? {
        lastFileURL.flatMap { exists($0) ? $0 : nil }
    }

    // Swift's min/max pass NaN through, so NaN gets its own check before clamping.
    private static func normalizedFontSize(_ value: Double) -> Double {
        value.isNaN ? defaultFontSize : min(max(value, minFontSize), maxFontSize)
    }

    private static func normalizedOpacity(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultOpacity }
        // Clamp first: for +/-infinity or huge values every distance ties and the first preset would win.
        let v = min(max(value, 0), 1)
        return opacityPresets.dropFirst().reduce(opacityPresets[0]) { best, p in
            abs(p - v) < abs(best - v) ? p : best
        }
    }

    private static func normalizedRecents(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return Array(urls.filter { seen.insert($0).inserted }.prefix(maxRecentFiles))
    }
}

/// Persists `Settings` as JSON in `UserDefaults`.
///
/// Why: isolates storage so tests can use a throwaway suite, and so a missing or
/// garbled blob degrades to defaults instead of failing app launch.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "settings.v1"

    /// Takes the defaults suite as a parameter so tests can inject a throwaway one.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns stored settings, or `Settings()` if absent or undecodable.
    public func load() -> Settings {
        defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    /// Writes `s` as JSON under `settings.v1`.
    public func save(_ s: Settings) {
        // Encoding a plain value struct of finite numbers and URLs cannot fail.
        defaults.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }
}
