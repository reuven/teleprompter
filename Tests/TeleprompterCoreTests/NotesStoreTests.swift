import Foundation
import PropertyBased
import Testing

@testable import TeleprompterCore

/// Counts `onExternalChange` calls. A class so the store's closure and the test share it.
@MainActor private final class Counter {
    var count = 0
}

/// Polls until `condition` holds, failing after `timeout`. The bounded wait, not a
/// sleep, is the pass condition.
@MainActor private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Saves the way BBEdit, VS Code, and Vim often do: write a temp file, rename it over the
/// original. `permissions` lets a test plant a file the store can't read.
private func atomicReplace(_ url: URL, with data: Data, permissions: Int? = nil) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
    try data.write(to: tmp)
    if let permissions {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: tmp.path)
    }
    #expect(rename(tmp.path, url.path) == 0)
}

private func contents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Each test gets its own temp directory (removed in `deinit`) holding the scratch file
/// and any opened files. Serialized because several tests assert on quiet windows, which
/// are more trustworthy without other watchers competing for the CPU.
@Suite(.serialized) @MainActor final class NotesStoreTests {
    let dir: URL
    let scratchURL: URL
    fileprivate let changes = Counter()

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchURL = dir.appendingPathComponent("Support/scratch.md")
    }

    deinit {
        // Restore permissions a test may have removed, so the directory can be deleted.
        let fm = FileManager.default
        if let items = fm.enumerator(atPath: dir.path) {
            for case let item as String in items {
                try? fm.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(item).path)
            }
        }
        try? fm.removeItem(at: dir)
    }

    /// A store on this test's scratch file whose external-change callback bumps `changes`.
    func makeStore(saveDelay: Duration = .milliseconds(10)) -> NotesStore {
        let store = NotesStore(scratchURL: scratchURL, saveDelay: saveDelay)
        store.onExternalChange = { [changes] in changes.count += 1 }
        return store
    }

    func makeFile(_ text: String, name: String = "talk.md") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Brief

    @Test func scratchPersists() async {
        let store = makeStore()
        store.userEdited("a")
        await store.flush()
        #expect(NotesStore(scratchURL: scratchURL).text == "a")
    }

    @Test func openLoadsFile() throws {
        let file = try makeFile("# Hi")
        let store = makeStore()
        store.open(file)
        #expect(store.text == "# Hi")
        #expect(store.source == .file(file))
        #expect(store.lastError == nil)
    }

    @Test func editSavesBackToFile() async throws {
        let file = try makeFile("old")
        let store = makeStore()
        store.open(file)
        store.userEdited("new")
        await store.flush()
        #expect(try contents(file) == "new")
    }

    @Test func externalChangeReloads() async throws {
        let file = try makeFile("old")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data("ext".utf8))
        #expect(await waitUntil { self.changes.count >= 1 })
        #expect(store.text == "ext")
        #expect(store.source == .file(file))
    }

    @Test func ownSaveDoesNotTriggerReload() async throws {
        let file = try makeFile("old")
        let store = makeStore()
        store.open(file)
        store.userEdited("mine")
        await store.flush()
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.count == 0)
        #expect(store.text == "mine")
    }

    @Test func closeFileRestoresScratch() async throws {
        let store = makeStore()
        store.userEdited("s")
        await store.flush()
        store.open(try makeFile("f"))
        #expect(store.text == "f")
        store.closeFile()
        #expect(store.text == "s")
        #expect(store.source == .scratch)
        #expect(try contents(scratchURL) == "s", "file text must never overwrite scratch")
    }

    @Test func missingFileSetsError() {
        let store = makeStore()
        store.open(dir.appendingPathComponent("nowhere.md"))
        #expect(store.lastError?.contains("nowhere.md") == true)
        #expect(store.source == .scratch)
    }

    @Test func nonUTF8SetsError() throws {
        let file = dir.appendingPathComponent("binary.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: file)
        let store = makeStore()
        store.userEdited("before")
        store.open(file)
        #expect(store.lastError?.contains("binary.md") == true)
        #expect(store.text == "before")
        #expect(store.source == .scratch)
    }

    @Test func deletedOpenFileFallsBack() async throws {
        let file = try makeFile("f", name: "gone-soon.md")
        let store = makeStore()
        store.open(file)
        try FileManager.default.removeItem(at: file)
        #expect(await waitUntil { store.source == .scratch })
        #expect(store.lastError?.contains("gone-soon.md") == true)
        #expect(store.lastError?.contains("discarded") == false, "nothing was pending")
    }

    @Test func scratchRoundTripsAnyUnicode() async {
        // Whole Unicode range minus surrogates (which aren't scalars), so emoji, RTL
        // scripts, combining marks, controls, "\r\n", and "" (empty array) all occur.
        let scalar = Gen.oneOf(
            Gen<UnicodeScalar>.unicodeScalar(in: "\u{0}"..."\u{D7FF}"),
            Gen<UnicodeScalar>.unicodeScalar(in: "\u{E000}"..."\u{10FFFF}"))
        let text = scalar.array(of: 0...40).map { String(String.UnicodeScalarView($0)) }
        await propertyCheck(input: text) { s in
            let store = NotesStore(scratchURL: scratchURL, saveDelay: .milliseconds(10))
            store.userEdited(s)
            await store.flush()
            #expect(
                NotesStore(scratchURL: scratchURL).text.unicodeScalars.elementsEqual(
                    s.unicodeScalars))
        }
    }

    @Test func scratchRoundTripsTrickyText() async {
        for s in ["", "\r\n", "👩‍👩‍👧 🇮🇱", "שלום עולם", "e\u{301}", "a\u{0}b", "\u{FEFF}bom"] {
            let store = NotesStore(scratchURL: scratchURL, saveDelay: .milliseconds(10))
            store.userEdited(s)
            await store.flush()
            #expect(
                NotesStore(scratchURL: scratchURL).text.unicodeScalars.elementsEqual(
                    s.unicodeScalars),
                "\(s.debugDescription)")
        }
    }

    // MARK: - Saving

    @Test func debouncedSaveHappensWithoutFlush() async throws {
        let file = try makeFile("old")
        let store = makeStore()
        store.open(file)
        store.userEdited("n")
        store.userEdited("ne")
        store.userEdited("new")
        #expect(await waitUntil { (try? contents(file)) == "new" })
        #expect(store.lastError == nil)
    }

    @Test func noSaveBeforeTheDelay() async throws {
        let file = try makeFile("old")
        let store = makeStore(saveDelay: .seconds(30))
        store.open(file)
        store.userEdited("new")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try contents(file) == "old")
        await store.flush()
        #expect(try contents(file) == "new")
    }

    @Test func eachEditRestartsTheDebounce() async throws {
        let file = try makeFile("old")
        let store = makeStore(saveDelay: .milliseconds(400))
        store.open(file)
        store.userEdited("first")
        try await Task.sleep(for: .milliseconds(200))
        store.userEdited("second")
        // 500 ms after the first edit but only 300 ms after the second: a first timer that
        // was not cancelled would already have written.
        try await Task.sleep(for: .milliseconds(300))
        #expect(try contents(file) == "old", "the second edit restarts the delay")
        #expect(await waitUntil { (try? contents(file)) == "second" })
    }

    @Test func flushWithNothingPendingWritesNothing() async {
        let store = makeStore()
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: scratchURL.path))
        #expect(store.lastError == nil)
    }

    @Test func scratchMissingStartsEmpty() {
        let store = makeStore()
        #expect(store.text == "")
        #expect(store.source == .scratch)
        #expect(store.lastError == nil)
    }

    @Test func unreadableScratchIsKeptAside() async throws {
        try FileManager.default.createDirectory(
            at: scratchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: scratchURL)
        let store = makeStore()
        #expect(store.text == "")
        let error = try #require(store.lastError)
        #expect(error.contains("scratch.md"))

        // The unreadable file is kept aside, not wiped by the first keystroke.
        let support = scratchURL.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: support.path)
            .filter { $0 != "scratch.md" }
        try #require(aside.count == 1)
        #expect(aside[0].wholeMatch(of: /scratch\.md\.unreadable-\d{8}-\d{6}/) != nil)
        #expect(error.contains(aside[0]))
        store.userEdited("fresh")
        await store.flush()
        #expect(try contents(scratchURL) == "fresh")
        #expect(
            try Data(contentsOf: support.appendingPathComponent(aside[0]))
                == Data([0xFF, 0xFE, 0x00]))
    }

    @Test func unmovableUnreadableScratchIsNeverOverwritten() async throws {
        let support = scratchURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: scratchURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: support.path)
        let store = makeStore()
        let error = try #require(store.lastError)
        #expect(error.contains("scratch.md") && error.contains("relaunch"))
        store.userEdited("typed")
        await store.flush()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: support.path)
        await store.flush()
        #expect(try Data(contentsOf: scratchURL) == Data([0xFF, 0xFE, 0x00]))
        #expect(store.text == "typed")
    }

    @Test func failedScratchSaveSetsErrorAndRetries() async throws {
        // No scratch file yet, and its directory is read-only, so the write itself fails.
        let support = scratchURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: support.path)
        let store = makeStore()
        #expect(store.lastError == nil)
        store.userEdited("kept?")
        await store.flush()
        #expect(store.lastError?.contains("scratch.md") == true)
        #expect(store.text == "kept?", "the user's text stays on screen")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: support.path)
        await store.flush()
        #expect(try contents(scratchURL) == "kept?")
    }

    @Test func scratchBehindARegularFileIsNotSaved() async throws {
        // The scratch file's "directory" is a regular file: unreadable and unmovable.
        let blocker = try makeFile("x", name: "blocker")
        let store = NotesStore(
            scratchURL: blocker.appendingPathComponent("scratch.md"), saveDelay: .milliseconds(10))
        #expect(store.lastError?.contains("relaunch") == true)
        store.userEdited("typed")
        await store.flush()
        #expect(store.text == "typed")
        #expect(try contents(blocker) == "x")
    }

    @Test func failedFileSaveSetsError() async throws {
        let sub = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("locked.md")
        try Data("old".utf8).write(to: file)
        let store = makeStore()
        store.open(file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        store.userEdited("new")
        await store.flush()
        #expect(store.lastError?.contains("locked.md") == true)
        #expect(try contents(file) == "old")
    }

    /// Makes `locked/locked.md` holding "old", opens it, then makes it unwritable.
    func openLockedFile(_ store: NotesStore) throws -> (dir: URL, file: URL) {
        let sub = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("locked.md")
        try Data("old".utf8).write(to: file)
        store.open(file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        return (sub, file)
    }

    func unlock(_ locked: (dir: URL, file: URL)) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: locked.dir.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: locked.file.path)
    }

    @Test func failedSaveIsRetriedByFlush() async throws {
        let store = makeStore()
        let locked = try openLockedFile(store)
        store.userEdited("new")
        await store.flush()
        #expect(store.lastError != nil)
        try unlock(locked)
        await store.flush()
        #expect(try contents(locked.file) == "new")
    }

    @Test func failedSaveIsRetriedByCloseFile() async throws {
        let store = makeStore()
        let locked = try openLockedFile(store)
        store.userEdited("new")
        await store.flush()
        try unlock(locked)
        store.closeFile()
        #expect(try contents(locked.file) == "new")
    }

    @Test func closeFileReportsEditsItCouldNotSave() async throws {
        let store = makeStore()
        let locked = try openLockedFile(store)
        store.userEdited("new")
        await store.flush()
        store.closeFile()
        #expect(store.source == .scratch)
        let error = try #require(store.lastError)
        #expect(error.contains("locked.md") && error.contains("discarded"))
        try unlock(locked)
        await store.flush()
        #expect(try contents(locked.file) == "old", "a discarded save stays discarded")
    }

    @Test func openReportsScratchEditsItCouldNotSave() async throws {
        let blocker = try makeFile("x", name: "blocker")
        let store = NotesStore(
            scratchURL: blocker.appendingPathComponent("scratch.md"), saveDelay: .seconds(30))
        store.userEdited("scratch typing")
        store.open(try makeFile("f"))
        #expect(store.source == .file(dir.appendingPathComponent("talk.md")))
        let error = try #require(store.lastError)
        #expect(error.contains("scratch.md") && error.contains("discarded"))
    }

    @Test func failedSaveIsKeptWhenOpenFails() async throws {
        let store = makeStore()
        let locked = try openLockedFile(store)
        store.userEdited("new")
        await store.flush()
        store.open(dir.appendingPathComponent("nowhere.md"))
        try unlock(locked)
        await store.flush()
        #expect(try contents(locked.file) == "new")
    }

    @Test func successfulOpenClearsError() throws {
        let store = makeStore()
        store.open(dir.appendingPathComponent("nowhere.md"))
        #expect(store.lastError != nil)
        store.open(try makeFile("ok", name: "there.md"))
        #expect(store.lastError == nil)
    }

    // MARK: - Switching sources

    @Test func pendingFileEditIsSavedOnClose() throws {
        let file = try makeFile("old")
        let store = makeStore(saveDelay: .seconds(30))
        store.open(file)
        store.userEdited("typed")
        store.closeFile()
        #expect(try contents(file) == "typed")
    }

    @Test func pendingScratchEditIsSavedOnOpen() throws {
        let store = makeStore(saveDelay: .seconds(30))
        store.userEdited("scratchy")
        store.open(try makeFile("f"))
        #expect(try contents(scratchURL) == "scratchy")
        store.closeFile()
        #expect(store.text == "scratchy")
    }

    @Test func failedOpenKeepsCurrentFile() throws {
        let file = try makeFile("first")
        let store = makeStore()
        store.open(file)
        store.open(dir.appendingPathComponent("nowhere.md"))
        #expect(store.source == .file(file))
        #expect(store.text == "first")
    }

    @Test func openingAnotherFileStopsWatchingTheFirst() async throws {
        let first = try makeFile("1", name: "first.md")
        let second = try makeFile("2", name: "second.md")
        let store = makeStore()
        store.open(first)
        store.open(second)
        try atomicReplace(first, with: Data("changed".utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.count == 0)
        #expect(store.text == "2")
    }

    @Test func closedFileIsNoLongerWatched() async throws {
        let file = try makeFile("old")
        let store = makeStore()
        store.open(file)
        store.closeFile()
        try atomicReplace(file, with: Data("ext".utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.count == 0)
        #expect(store.text == "")
    }

    @Test func closeFileWhenAlreadyScratchIsHarmless() {
        let store = makeStore()
        store.userEdited("s")
        store.closeFile()
        #expect(store.text == "s")
        #expect(store.source == .scratch)
    }

    // MARK: - Reloading

    @Test func externalChangeBeatsPendingSave() async throws {
        let file = try makeFile("old")
        let store = makeStore(saveDelay: .seconds(30))
        store.open(file)
        store.userEdited("mine")
        try atomicReplace(file, with: Data("ext".utf8))
        #expect(await waitUntil { self.changes.count >= 1 })
        #expect(store.text == "ext")
        await store.flush()
        #expect(try contents(file) == "ext", "the cancelled save must not clobber the edit")
    }

    @Test func repeatedEventsWithSameContentReloadOnce() async throws {
        let file = try makeFile("old")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data("ext".utf8))
        #expect(await waitUntil { self.changes.count >= 1 })
        try atomicReplace(file, with: Data("ext".utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.count == 1)
    }

    @Test func nonUTF8ReloadKeepsTextAndSource() async throws {
        let file = try makeFile("good")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data([0xFF, 0xFE, 0x00]))
        #expect(await waitUntil { store.lastError != nil })
        #expect(store.lastError?.contains("talk.md") == true)
        #expect(store.text == "good")
        #expect(store.source == .file(file))
        #expect(changes.count == 0)
    }

    @Test func unreadableReloadKeepsTextAndSource() async throws {
        let file = try makeFile("good")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data("secret words".utf8), permissions: 0o000)
        #expect(await waitUntil { store.lastError != nil })
        #expect(store.lastError?.contains("talk.md") == true)
        #expect(store.lastError?.contains("secret") == false)
        #expect(store.text == "good")
        #expect(store.source == .file(file))
    }

    @Test func goodReloadClearsReloadError() async throws {
        let file = try makeFile("good")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data([0xFF, 0xFE, 0x00]))
        #expect(await waitUntil { store.lastError != nil })
        store.userEdited("held")
        try atomicReplace(file, with: Data("fixed".utf8))
        #expect(await waitUntil { store.text == "fixed" })
        #expect(store.lastError == nil)
        await store.flush()
        #expect(try contents(file) == "fixed", "the other editor's fix wins over held edits")
        store.userEdited("resumed")
        await store.flush()
        #expect(try contents(file) == "resumed")
    }

    @Test func failedReloadSuspendsSavingToFile() async throws {
        let file = try makeFile("good")
        let store = makeStore(saveDelay: .seconds(30))
        store.open(file)
        store.userEdited("mine")
        let theirs = Data([0xFF, 0xFE, 0x00])
        try atomicReplace(file, with: theirs)
        #expect(await waitUntil { store.lastError != nil })
        let error = try #require(store.lastError)
        #expect(error.contains("talk.md") && error.contains("not being saved"))
        await store.flush()
        #expect(try Data(contentsOf: file) == theirs)
        store.userEdited("more")
        await store.flush()
        #expect(try Data(contentsOf: file) == theirs)
        #expect(store.text == "more", "edits stay on screen")
    }

    @Test func revertAfterFailedReloadResumesSaving() async throws {
        let file = try makeFile("good")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data([0xFF, 0xFE, 0x00]))
        #expect(await waitUntil { store.lastError != nil })
        store.userEdited("held")
        await store.flush()
        // The other program puts back exactly the bytes we know.
        try atomicReplace(file, with: Data("good".utf8))
        #expect(await waitUntil { store.lastError == nil })
        #expect(await waitUntil { (try? contents(file)) == "held" }, "held edits are saved")
        #expect(store.text == "held")
        #expect(changes.count == 0)
    }

    @Test func revertWithNoHeldEditsJustClearsError() async throws {
        let file = try makeFile("good")
        let store = makeStore()
        store.open(file)
        try atomicReplace(file, with: Data([0xFF, 0xFE, 0x00]))
        #expect(await waitUntil { store.lastError != nil })
        try atomicReplace(file, with: Data("good".utf8))
        #expect(await waitUntil { store.lastError == nil })
        store.userEdited("after")
        await store.flush()
        #expect(try contents(file) == "after")
    }

    @Test func unreadableOpenErrorNamesFileNotContents() throws {
        let file = try makeFile("secret words", name: "private.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let store = makeStore()
        store.open(file)
        let error = try #require(store.lastError)
        #expect(error.contains("private.md"))
        #expect(!error.contains("secret"))
        #expect(!error.contains("\n"))
        #expect(store.source == .scratch)
    }

    @Test func deletedFileIsNeverRecreated() async throws {
        let store = makeStore(saveDelay: .seconds(30))
        store.userEdited("scratch text")
        let file = try makeFile("f", name: "gone.md")
        store.open(file)
        store.userEdited("typed into file")
        try FileManager.default.removeItem(at: file)
        #expect(await waitUntil { store.source == .scratch })
        #expect(store.text == "scratch text")
        #expect(changes.count == 1, "the UI must be told to refresh")
        let error = try #require(store.lastError)
        #expect(error.contains("gone.md") && !error.contains("\n"))
        #expect(error.contains("discarded"), "the pending edit was lost; say so")

        await store.flush()
        store.userEdited("later")
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try contents(scratchURL) == "later")

        // The watcher was stopped: the file coming back is not picked up.
        try Data("back".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.source == .scratch)
        #expect(changes.count == 1)
    }
}
