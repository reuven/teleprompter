import Foundation

/// Where the notes text currently lives, and therefore where edits are saved.
///
/// Why two cases: scratch notes are the app's own file and always exist, while an opened
/// Markdown file belongs to the user and can be edited, replaced, or deleted by other
/// programs. Keeping the distinction explicit lets the store fall back to scratch safely.
public enum NotesSource: Equatable, Sendable {
    /// The app's own autosaved notes file.
    case scratch
    /// A Markdown file the user opened; edits are saved back to it.
    case file(URL)
}

/// The model behind the notes window: the text, where it comes from, and keeping it in sync
/// with disk in both directions.
///
/// Why it exists: the failure to avoid is silent data loss, either losing what the user
/// typed or clobbering a file another editor just saved. So:
/// - Edits are saved after a short debounce (`saveDelay`), always with atomic writes. A
///   failed save stays pending, so `flush()` or a source switch retries it; if it still
///   can't be written when the source switches, it is dropped and `lastError` says so.
/// - An open file is watched; a change made by *another* program reloads `text` and calls
///   `onExternalChange`. Our own saves are recognized by their exact bytes and ignored.
/// - Last write wins (accepted in the spec): if another program changes the file while one
///   of our saves is still pending, the external change wins and the pending save is
///   cancelled, because silently overwriting a deliberate save in another editor is worse
///   than dropping the last fraction of a second of typing that the reload replaces anyway.
/// - If a reload can't read the file (not UTF-8, no permission), saving to it is suspended:
///   we can't tell what another program put there, so we must not overwrite it. Edits stay
///   on screen and are held. If the file goes back to exactly the bytes we last knew, the
///   held edits are saved and saving resumes. If it becomes readable with new content, that
///   content wins (as above) and the held edits are dropped.
/// - If the open file vanishes for good, the store falls back to scratch and reports it in
///   `lastError` (including whether unsaved edits were dropped). It never recreates the
///   vanished file by saving to it.
/// - Scratch text is never overwritten by file contents; `closeFile()` returns to it. A
///   scratch file that exists but can't be read is renamed aside before anything is saved,
///   so the first keystroke can't wipe it; if it can't be renamed, scratch isn't saved at all
///   until the next launch.
///
/// It does not own recent files or the last-opened file; the app wires those to `Settings`.
@MainActor public final class NotesStore {
    /// The text the window shows. Changed by `userEdited`, `open`, `closeFile`, and reloads.
    public private(set) var text: String
    /// Where `text` came from and where edits go.
    public private(set) var source: NotesSource = .scratch
    /// A one-line, user-facing description of the last problem (naming the file, never
    /// quoting its contents), or nil. Cleared by a successful open or reload.
    public private(set) var lastError: String?
    /// Called after `text` or `source` changed because of something outside the app (another
    /// program edited the file, or the file vanished), so the UI can refresh. Not called for
    /// changes the app made itself.
    public var onExternalChange: (() -> Void)?

    private let scratchURL: URL
    private let saveDelay: Duration
    /// The latest scratch text. Kept separately so an open file's text never replaces it.
    private var scratchText: String
    /// True when an unreadable scratch file couldn't be moved aside: saving would destroy it.
    private var scratchSavesDisabled = false
    /// The text not yet written (waiting for the debounce, failed, or held), and where it
    /// must be written.
    private var pending: (target: NotesSource, text: String)?
    private var pendingTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    /// The open file's bytes as we last wrote or read them. A watcher event that finds
    /// exactly these bytes is our own save (or a repeat event) and is ignored.
    private var knownFileBytes: Data?
    /// True while the open file holds content we couldn't read; edits to it are held.
    private var fileSavesSuspended = false

    /// Loads scratch notes from `scratchURL` (empty if the file doesn't exist yet).
    ///
    /// `saveDelay` is the debounce: edits are written once typing pauses this long. Tests
    /// pass a few milliseconds; the default suits interactive typing.
    public init(scratchURL: URL, saveDelay: Duration = .milliseconds(500)) {
        self.scratchURL = scratchURL
        self.saveDelay = saveDelay
        switch Self.read(scratchURL) {
        case .success(let loaded):
            scratchText = loaded.text
        case .failure(.missing):
            scratchText = ""
        case .failure(let failure):
            scratchText = ""
            (lastError, scratchSavesDisabled) = Self.moveUnreadableScratchAside(
                scratchURL, failure)
        }
        text = scratchText
    }

    /// Opens a Markdown file: shows its text, saves edits back to it, and watches it for
    /// changes made by other programs.
    ///
    /// On failure (missing file, unreadable, not UTF-8) nothing changes except `lastError`,
    /// so a bad pick in the Open dialog never loses the current notes.
    public func open(_ url: URL) {
        savePendingNow()
        // Watch first, then read: a write landing between the two is then either in what
        // we read or reported by the watcher, never lost.
        let newWatcher = FileWatcher(url: url, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.fileDidChange(url) }
        }
        switch Self.read(url) {
        case .success(let loaded):
            let dropped = dropUnsavedEdits()
            watcher?.stop()
            watcher = newWatcher
            source = .file(url)
            text = loaded.text
            knownFileBytes = loaded.data
            fileSavesSuspended = false
            lastError = dropped
        case .failure(let failure):
            newWatcher.stop()
            lastError = Self.message("Couldn't open", url, failure)
        }
    }

    /// Stops using the open file and returns to scratch notes, as they were last saved.
    /// Any pending edit to the file is saved first (or reported if it can't be).
    public func closeFile() {
        savePendingNow()
        if case .file = source, let dropped = dropUnsavedEdits() {
            lastError = dropped
        }
        switchToScratch()
    }

    /// Records the user's typing and schedules a debounced save to the current source.
    ///
    /// Each call restarts the delay, so a burst of keystrokes produces one write.
    public func userEdited(_ newText: String) {
        text = newText
        if source == .scratch { scratchText = newText }
        pending = (source, newText)
        pendingTask?.cancel()
        pendingTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            // Superseded by a newer edit, a flush, or an external change.
            guard !Task.isCancelled else { return }
            self?.savePendingNow()
        }
    }

    /// Writes any pending save immediately (retrying one that failed). Called on quit, so
    /// the last keystrokes are not lost to the debounce, and by tests.
    public func flush() async {
        savePendingNow()
    }

    // MARK: - Saving

    /// Writes `pending` if its destination may be written; otherwise, or on failure, keeps
    /// it so a later flush or source switch can retry.
    private func savePendingNow() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let save = pending else { return }
        let data = Data(save.text.utf8)
        switch save.target {
        case .scratch:
            guard !scratchSavesDisabled else { return }
            do {
                try FileManager.default.createDirectory(
                    at: scratchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: scratchURL, options: .atomic)
                pending = nil
            } catch {
                lastError = "Couldn't save “\(scratchURL.lastPathComponent)”."
            }
        case .file(let url):
            guard !fileSavesSuspended else { return }
            do {
                try data.write(to: url, options: .atomic)
                knownFileBytes = data
                pending = nil
            } catch {
                lastError = "Couldn't save “\(url.lastPathComponent)”."
            }
        }
    }

    /// Drops any pending save without writing it.
    private func cancelPendingSave() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
    }

    /// Called when leaving a source after trying to save: drops what couldn't be written
    /// and returns a message saying so, or nil if nothing was lost.
    private func dropUnsavedEdits() -> String? {
        guard let save = pending else { return nil }
        cancelPendingSave()
        let name =
            switch save.target {
            case .scratch: scratchURL.lastPathComponent
            case .file(let url): url.lastPathComponent
            }
        return "Changes to “\(name)” couldn't be saved and were discarded."
    }

    private func switchToScratch() {
        watcher?.stop()
        watcher = nil
        knownFileBytes = nil
        fileSavesSuspended = false
        source = .scratch
        text = scratchText
    }

    /// Renames an unreadable scratch file to `<name>.unreadable-<yyyyMMdd-HHmmss>` so the
    /// first save can't destroy it. Returns the message for `lastError`, and whether scratch
    /// saving must be disabled for this run because the rename failed.
    private static func moveUnreadableScratchAside(
        _ scratchURL: URL, _ failure: ReadFailure
    ) -> (message: String, disableSaves: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let asideName = "\(scratchURL.lastPathComponent).unreadable-\(formatter.string(from: .now))"
        let problem = Self.message("Couldn't load", scratchURL, failure)
        do {
            try FileManager.default.moveItem(
                at: scratchURL,
                to: scratchURL.deletingLastPathComponent().appending(path: asideName))
            return ("\(problem) It was kept as “\(asideName)”.", false)
        } catch {
            return ("\(problem) Scratch notes won't be saved until you relaunch.", true)
        }
    }

    // MARK: - Reloading

    /// The watcher's "re-read the file now". Runs on the main queue.
    ///
    /// `url` is always the open file: every path that changes `source` stops the old
    /// watcher first, and `FileWatcher.stop()` guarantees no callback after it returns.
    private func fileDidChange(_ url: URL) {
        switch Self.read(url) {
        case .success(let loaded) where loaded.data == knownFileBytes:
            // Our own save, a repeat event, or a revert after a failed reload.
            if fileSavesSuspended {
                fileSavesSuspended = false
                lastError = nil
                savePendingNow()  // The file is as we left it, so held edits are safe to write.
            }
            return
        case .success(let loaded):
            cancelPendingSave()  // The external change wins; see the type's doc comment.
            text = loaded.text
            knownFileBytes = loaded.data
            fileSavesSuspended = false
            lastError = nil
        case .failure(.missing):
            // The watcher gave up waiting for it: the file is gone for good. Drop the
            // pending save so the file is never recreated, and show scratch instead.
            let discarded = pending == nil ? "" : " Unsaved changes to it were discarded."
            cancelPendingSave()
            switchToScratch()
            lastError =
                "“\(url.lastPathComponent)” was moved or deleted; showing scratch notes.\(discarded)"
        case .failure(let failure):
            // We can't see what another program put there, so we must not overwrite it.
            fileSavesSuspended = true
            pendingTask?.cancel()
            pendingTask = nil
            lastError =
                "\(Self.message("Couldn't reload", url, failure)) Edits are not being saved to it."
            return
        }
        onExternalChange?()
    }

    // MARK: - Reading

    private enum ReadFailure: Error {
        case missing, notUTF8, unreadable
    }

    private static func read(_ url: URL) -> Result<(data: Data, text: String), ReadFailure> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .failure(.missing)
        } catch {
            return .failure(.unreadable)
        }
        guard let text = String(validating: data, as: UTF8.self) else {
            return .failure(.notUTF8)
        }
        return .success((data, text))
    }

    /// One line naming the file and the reason, never its contents.
    private static func message(_ action: String, _ url: URL, _ failure: ReadFailure) -> String {
        let reason =
            switch failure {
            case .missing: "the file doesn't exist"
            case .notUTF8: "it isn't UTF-8 text"
            case .unreadable: "it can't be read"
            }
        return "\(action) “\(url.lastPathComponent)”: \(reason)."
    }
}
