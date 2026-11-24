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
///   can't be written when the source switches, an edit to a file is dropped and `lastError`
///   says so, while scratch edits are kept in memory and saved by `flush()` or on returning
///   to scratch.
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
    /// quoting its contents), or nil.
    ///
    /// Cleared by a successful open or reload, by `dismissError()`, and by a successful save
    /// when the error was that save's own earlier failure (other errors stay until dismissed).
    /// A problem that persists is raised again on the next attempt: a failed save sets it
    /// every time, and blocked scratch saving (see the type's doc comment) re-raises it if the
    /// user dismissed it, so a save that isn't happening never goes silent.
    public private(set) var lastError: String? {
        didSet { if lastError != oldValue { onErrorChange?() } }
    }
    /// Called after `text` or `source` changed because of something outside the app (another
    /// program edited the file, or the file vanished), so the UI can refresh. Not called for
    /// changes the app made itself.
    public var onExternalChange: (() -> Void)?
    /// Called whenever `lastError` changes, whatever the cause (including a debounced save
    /// failing with no user action in progress), so the UI can show or hide the error at once.
    /// Separate from `onExternalChange` because an error is not a change to the notes.
    public var onErrorChange: (() -> Void)?

    /// True while some edit isn't on disk: a save is waiting, failed, or held, or scratch edits
    /// were kept in memory when a file was opened. The app asks before quitting with this set,
    /// so notes are never lost silently.
    public var hasUnsavedChanges: Bool { pending != nil || scratchUnsaved }

    /// The message to show when quitting with unsaved changes: `lastError` if it describes why
    /// something isn't saved (a failed save, held saves, kept scratch edits, blocked scratch
    /// saving), else nil, so an unrelated error ("Couldn't open …") is never shown as the reason.
    public var unsavedChangesReason: String? {
        guard hasUnsavedChanges, let lastError else { return nil }
        let reasons = [
            fileFailureMessage, fileSavesSuspended ? suspendedMessage : nil, scratchFailureMessage,
        ]
        return reasons.contains(lastError) ? lastError : nil
    }

    /// The largest file `open` accepts, in bytes (2 MB). Notes are a page or two; anything
    /// bigger is almost certainly the wrong file, and fitting it would stall the reader.
    public static let maxFileSize = 2 * 1024 * 1024

    /// Whether `url` is an existing, readable regular file (not a folder). The app uses it to
    /// decide quietly, at launch, whether the last file can be reopened.
    public static func isOpenableFile(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue
            && fm.isReadableFile(atPath: url.path)
    }

    private let scratchURL: URL
    private let saveDelay: Duration
    /// The latest scratch text. Kept separately so an open file's text never replaces it.
    private var scratchText: String
    /// True when an unreadable scratch file couldn't be moved aside: saving would destroy it.
    private var scratchSavesDisabled = false
    /// True when scratch edits couldn't be saved before a file was opened. `scratchText` still
    /// holds them; they're saved by `flush()` or on returning to scratch.
    private var scratchUnsaved = false
    /// The message a failed scratch save (or kept scratch edits) put in `lastError`; only a
    /// successful scratch write makes it stale.
    private var scratchFailureMessage: String?
    /// The message a failed file save put in `lastError`; only a successful file save makes it
    /// stale.
    private var fileFailureMessage: String?
    /// The message for suspended file saving, raised again if dismissed while still suspended.
    private var suspendedMessage: String?
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
    ///
    /// Also refused, with a message: the scratch file itself (by any path or symlink), which
    /// would make one file two sources, and files over `maxFileSize`.
    ///
    /// A symlink is resolved first, and the target is what's watched, saved, and reported as
    /// `source`: an atomic save writes a temporary file and renames it over the path, so saving
    /// through the link would replace the link itself with a regular file and leave the real
    /// file behind, unchanged.
    public func open(_ requested: URL) {
        let url = Self.resolved(requested)
        if Self.isSameFile(url, scratchURL) {
            lastError =
                "“\(requested.lastPathComponent)” holds the scratch notes; they're shown whenever no file is open."
            return
        }
        savePendingNow()
        // Watch first, then read: a write landing between the two is then either in what
        // we read or reported by the watcher, never lost.
        let newWatcher = FileWatcher(url: url, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.fileDidChange(url) }
        }
        switch Self.read(url, maxSize: Self.maxFileSize) {
        case .success(let loaded):
            let dropped = dropUnsavedEdits()
            watcher?.stop()
            watcher = newWatcher
            source = .file(url)
            text = loaded.text
            knownFileBytes = loaded.data
            fileSavesSuspended = false
            fileFailureMessage = nil
            lastError = dropped
        case .failure(let failure):
            newWatcher.stop()
            lastError = Self.message("Couldn't open", requested, failure)
        }
    }

    /// Clears `lastError` once the user has seen it. A problem that is still there comes back on
    /// the next attempt (see `lastError`).
    public func dismissError() {
        lastError = nil
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
        if scratchUnsaved { _ = writeScratch(Data(scratchText.utf8)) }
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
            if writeScratch(data) { pending = nil }
        case .file(let url):
            guard !fileSavesSuspended else {
                // Held, not saved: if the user dismissed the notice, say so again.
                if lastError == nil { lastError = suspendedMessage }
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                knownFileBytes = data
                pending = nil
                clearIfStale(&fileFailureMessage)
            } catch {
                fileFailureMessage = "Couldn't save “\(url.lastPathComponent)”."
                lastError = fileFailureMessage
            }
        }
    }

    /// Writes scratch notes, creating the folder on first use. Returns whether it worked;
    /// failures (and blocked saving) are reported in `lastError`.
    ///
    /// Every scratch write carries the whole of `scratchText` (scratch edits update it and the
    /// pending save together), so a success means no kept scratch edits remain.
    private func writeScratch(_ data: Data) -> Bool {
        guard !scratchSavesDisabled else {
            // Keep the fuller launch message if it's still up; re-raise once it's dismissed.
            if lastError == nil { lastError = Self.scratchBlocked }
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: scratchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: scratchURL, options: .atomic)
            scratchUnsaved = false
            clearIfStale(&scratchFailureMessage)
            return true
        } catch {
            // Kept scratch edits keep their fuller "kept" notice through a failed retry.
            if !scratchUnsaved || scratchFailureMessage == nil {
                scratchFailureMessage = "Couldn't save “\(scratchURL.lastPathComponent)”."
            }
            lastError = scratchFailureMessage
            return false
        }
    }

    /// A save to one target worked, so that target's own failure message is out of date. Clears
    /// `lastError` only if it still shows that message: another target's problem stays up.
    ///
    /// Kept scratch edits are still unsaved after another target's success, so their notice
    /// comes back rather than going silent.
    private func clearIfStale(_ message: inout String?) {
        if let stale = message, lastError == stale {
            lastError = scratchUnsaved ? scratchFailureMessage : nil
        }
        message = nil
    }

    private static let scratchBlocked = "Scratch notes can't be saved until you relaunch."

    /// Drops any pending save without writing it.
    private func cancelPendingSave() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
    }

    /// Called when leaving a source after trying to save: drops the pending save that couldn't
    /// be written and returns a message saying what happened to it, or nil if nothing was
    /// pending.
    ///
    /// Edits to a file are discarded. Scratch edits are not: `scratchText` still holds them,
    /// so they're marked unsaved and saved later (see `scratchUnsaved`), and the message says
    /// they were kept.
    private func dropUnsavedEdits() -> String? {
        guard let save = pending else { return nil }
        cancelPendingSave()
        switch save.target {
        case .scratch:
            scratchUnsaved = true
            let message =
                scratchSavesDisabled
                ? "\(Self.scratchBlocked) Your scratch edits are kept until you quit."
                : "Couldn't save scratch notes. They're kept, and saved when you close this file or quit."
            // Stale once a scratch write succeeds, which also clears `scratchUnsaved`.
            scratchFailureMessage = message
            return message
        case .file(let url):
            return "Changes to “\(url.lastPathComponent)” couldn't be saved and were discarded."
        }
    }

    private func switchToScratch() {
        watcher?.stop()
        watcher = nil
        knownFileBytes = nil
        fileSavesSuspended = false
        fileFailureMessage = nil
        source = .scratch
        text = scratchText
        if scratchUnsaved {
            scratchUnsaved = false
            pending = (.scratch, scratchText)
            savePendingNow()
        }
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
        // Over the size limit counts as unreadable: not loaded, and saves are held.
        switch Self.read(url, maxSize: Self.maxFileSize) {
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
            suspendedMessage =
                "\(Self.message("Couldn't reload", url, failure)) Edits are not being saved to it."
            lastError = suspendedMessage
            return
        }
        onExternalChange?()
    }

    // MARK: - Reading

    /// Whether `a` and `b` name the same file: by file identity when both exist (catching any
    /// spelling, case, or link), else by resolved path, ignoring case as macOS volumes usually
    /// do.
    ///
    /// Symlinks are resolved first: a link's own resource values describe the link, not the file.
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let (a, b) = (resolved(a), resolved(b))
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let idA = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
            let idB = try? b.resourceValues(forKeys: key).fileResourceIdentifier
        {
            return idA.isEqual(idB)
        }
        return a.path.lowercased() == b.path.lowercased()
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private enum ReadFailure: Error {
        case missing, notUTF8, unreadable, tooLarge
    }

    /// Reads `url` as UTF-8 text. With `maxSize`, a larger file is refused before reading it.
    private static func read(_ url: URL, maxSize: Int? = nil) -> Result<
        (data: Data, text: String), ReadFailure
    > {
        if let maxSize, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > maxSize
        {
            return .failure(.tooLarge)
        }
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
            case .tooLarge: "it's larger than 2 MB"
            }
        return "\(action) “\(url.lastPathComponent)”: \(reason)."
    }
}
