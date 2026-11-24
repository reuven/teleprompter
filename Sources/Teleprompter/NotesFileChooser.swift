import AppKit
import UniformTypeIdentifiers

/// Configures the Open… dialog so only notes files (`.md`, `.markdown`, `.txt`) can be picked.
///
/// Why a delegate as well as `allowedContentTypes`: `.txt` maps to plain text, which every kind
/// of source file conforms to, so the type list alone would let `.swift` or `.log` through. The
/// delegate enables files by extension only, leaving folders enabled so the user can browse.
///
/// Capture limit: `NSOpenPanel` is drawn mostly by a separate system process, so `CaptureShield`
/// can't hide it and the dialog itself may appear in a recording. That is accepted: it shows file
/// names, never the notes. Showing it changes nothing about the notes panel, whose capture
/// setting is fixed in its `init`.
@MainActor
final class NotesFileChooser: NSObject, NSOpenSavePanelDelegate {
    /// The extensions Open… accepts, lowercase.
    static let extensions = ["md", "markdown", "txt"]

    /// The types for `allowedContentTypes`, without repeats: `.md` and `.markdown` are both
    /// Markdown, and the panel keeps only one of each.
    static let contentTypes = extensions.compactMap { UTType(filenameExtension: $0) }.reduce(
        into: [UTType]()
    ) { types, type in
        if !types.contains(type) { types.append(type) }
    }

    /// Whether `url` may be picked: a folder (to browse into) or a file with a notes extension.
    static func accepts(_ url: URL) -> Bool {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isFolder || extensions.contains(url.pathExtension.lowercased())
    }

    /// Sets `panel` up for picking a single notes file, with this object as its filter. The
    /// panel holds its delegate weakly, so the caller keeps this object alive while it runs.
    func configure(_ panel: NSOpenPanel) {
        panel.allowedContentTypes = Self.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.delegate = self
    }

    /// Greys out every file that isn't a notes file (see `accepts`).
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        Self.accepts(url)
    }
}
