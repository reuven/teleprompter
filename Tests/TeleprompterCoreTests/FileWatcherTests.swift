import Foundation
import Synchronization
import Testing

@testable import TeleprompterCore

/// Records every callback together with the file's content *at callback time*, which is
/// what a real reader (NotesStore) would see.
private final class Recorder: Sendable {
    private let seen = Mutex<[String]>([])

    let url: URL
    init(url: URL) { self.url = url }

    /// The callback to hand to `FileWatcher`.
    var callback: @Sendable () -> Void {
        { [self] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
            seen.withLock { $0.append(text) }
        }
    }

    var count: Int { seen.withLock { $0.count } }
    var last: String? { seen.withLock { $0.last } }

    /// Polls until `condition` holds, failing after `timeout`. The bounded wait, not a
    /// sleep, is the pass condition.
    func waitUntil(
        timeout: Duration = .seconds(2), _ condition: (Recorder) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(self)
    }
}

/// A fresh temp directory holding `notes.md` with `initial` content.
private func makeFile(_ initial: String = "start") throws -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("notes.md")
    try Data(initial.utf8).write(to: file)
    return (dir, file)
}

private func inode(_ url: URL) throws -> UInt64 {
    try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
}

/// Saves the way BBEdit, VS Code, and Vim often do: write a temp file, rename it over the
/// original. The original inode disappears, which is what silences a naive watcher.
private func atomicReplace(_ url: URL, with text: String) throws {
    let before = try inode(url)
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
    try Data(text.utf8).write(to: tmp)
    #expect(rename(tmp.path, url.path) == 0)
    #expect(try inode(url) != before, "rename must really replace the inode")
}

/// How many of this process's descriptors refer to `url`. A stopped watcher must hold
/// none, or it leaks a descriptor (and keeps its dispatch source alive) for good.
private func descriptors(to url: URL) -> Int {
    guard let real = realpath(url.path, nil) else { return 0 }
    defer { free(real) }
    let target = String(cString: real)
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return (0..<getdtablesize()).count { fd in
        fcntl(fd, F_GETPATH, &buffer) != -1
            && String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                == target
    }
}

/// Polls (bounded) until no descriptor refers to `url`; `stop()` closes asynchronously.
private func waitForNoDescriptors(to url: URL) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while descriptors(to: url) > 0 && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return descriptors(to: url) == 0
}

private func append(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

/// Serializes the suite: each test asserts on quiet windows, which are more trustworthy
/// without a dozen other watchers and file writes competing for the CPU.
@Suite(.serialized) struct FileWatcherTests {
    let queue = DispatchQueue(label: "FileWatcherTests.callbacks")

    @Test func firesOnInPlaceWrite() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        defer { watcher.stop() }

        try append(file, " more")
        #expect(await rec.waitUntil { $0.count >= 1 })
        #expect(await rec.waitUntil { $0.last == "start more" })
    }

    @Test func survivesRepeatedAtomicReplace() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        defer { watcher.stop() }

        for text in ["a", "b", "c"] {
            let before = rec.count
            try atomicReplace(file, with: text)
            #expect(await rec.waitUntil { $0.count > before }, "no change after saving \(text)")
            // The reader must see the new content, so it never misses the final save.
            #expect(await rec.waitUntil { $0.last == text }, "missed content \(text)")
        }
        // And the replacement inode is really being watched, not just announced once.
        let before = rec.count
        try append(file, "!")
        #expect(await rec.waitUntil { $0.count > before && $0.last == "c!" })
    }

    @Test func stopsAfterStop() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        #expect(descriptors(to: file) == 1)

        watcher.stop()
        #expect(await waitForNoDescriptors(to: file))
        try append(file, " more")
        try atomicReplace(file, with: "replaced")
        #expect(await !rec.waitUntil(timeout: .milliseconds(300)) { $0.count > 0 })
    }

    @Test func stopIsIdempotentAndDeinitSafe() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        do {
            let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
            watcher.stop()
            watcher.stop()
        }  // deinit calls stop() a third time
        do {
            _ = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        }  // deinit alone must stop it
        try append(file, " more")
        #expect(await !rec.waitUntil(timeout: .milliseconds(300)) { $0.count > 0 })
    }

    @Test func stopDropsCallbackAlreadyQueued() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let held = DispatchQueue(label: "FileWatcherTests.held")
        let watcher = FileWatcher(url: file, queue: held, onChange: rec.callback)

        // Hold the caller's queue so the change is queued for delivery but not yet run.
        held.suspend()
        try append(file, " more")
        try await Task.sleep(for: .milliseconds(200))  // setup: let the event be queued
        watcher.stop()
        held.resume()
        #expect(await !rec.waitUntil(timeout: .milliseconds(300)) { $0.count > 0 })
    }

    @Test func stopFromInsideCallbackDoesNotDeadlock() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let box = Mutex<FileWatcher?>(nil)
        let watcher = FileWatcher(url: file, queue: queue) {
            rec.callback()
            box.withLock { $0?.stop() }
        }
        box.withLock { $0 = watcher }

        try append(file, "1")
        #expect(await rec.waitUntil { $0.count == 1 })
        try append(file, "2")
        #expect(await !rec.waitUntil(timeout: .milliseconds(300)) { $0.count > 1 })
        box.withLock { $0 = nil }
    }

    @Test func deliversOnMainQueueByDefault() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let onMain = Mutex<[Bool]>([])
        let watcher = FileWatcher(url: file) {
            onMain.withLock { $0.append(Thread.isMainThread) }
        }
        defer { watcher.stop() }

        try append(file, " more")
        let deadline = ContinuousClock.now + .seconds(2)
        while onMain.withLock({ $0.isEmpty }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(onMain.withLock { !$0.isEmpty && $0.allSatisfy { $0 } })
    }

    @Test func vanishedFileReportsOnceAfterGivingUp() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        defer { watcher.stop() }

        let deleted = ContinuousClock.now
        try FileManager.default.removeItem(at: file)
        // Exactly one final callback, after the 10 x 50 ms retry window, so the reader
        // finds the file missing (NotesStore then switches to scratch).
        #expect(await rec.waitUntil { $0.count >= 1 })
        #expect(ContinuousClock.now - deleted >= .milliseconds(450), "fired before the retries")
        #expect(rec.last == "<missing>")
        #expect(descriptors(to: file) == 0)
        // Having given up, it stays idle even when the file later reappears.
        try Data("back".utf8).write(to: file)
        try append(file, " again")
        #expect(await !rec.waitUntil(timeout: .milliseconds(300)) { $0.count > 1 })
        #expect(rec.count == 1)
        #expect(descriptors(to: file) == 0)
    }

    @Test func recoversWhenFileReappearsWithinRetryWindow() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        defer { watcher.stop() }

        // Vim-style save: move the original aside, then write a new file at the path.
        let backup = dir.appendingPathComponent("notes.md~")
        try FileManager.default.moveItem(at: file, to: backup)
        try await Task.sleep(for: .milliseconds(150))  // setup: force at least one retry
        try Data("rewritten".utf8).write(to: file)
        #expect(await rec.waitUntil { $0.last == "rewritten" })

        let before = rec.count
        try append(file, "!")
        #expect(await rec.waitUntil { $0.count > before && $0.last == "rewritten!" })
    }

    @Test func stopDuringRetryWindowDoesNotResurrect() async throws {
        let (dir, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)

        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .milliseconds(100))  // setup: watcher is now retrying
        watcher.stop()
        try Data("back".utf8).write(to: file)
        #expect(await !rec.waitUntil(timeout: .milliseconds(600)) { $0.count > 0 })
        // A pending retry must not reopen the file behind a stopped watcher.
        #expect(descriptors(to: file) == 0)
    }

    @Test func missingFileAtStartReportsOnceAfterGivingUp() async throws {
        let (dir, _) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("absent.md")
        let rec = Recorder(url: file)
        let started = ContinuousClock.now
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        defer { watcher.stop() }

        #expect(await rec.waitUntil { $0.count >= 1 })
        #expect(ContinuousClock.now - started >= .milliseconds(450), "fired before the retries")
        #expect(rec.last == "<missing>")
        try Data("now here".utf8).write(to: file)
        #expect(await !rec.waitUntil(timeout: .milliseconds(300)) { $0.count > 1 })
        #expect(descriptors(to: file) == 0)
    }

    @Test func fileAppearingSoonAfterStartIsWatchedSilently() async throws {
        let (dir, _) = try makeFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("late.md")
        let rec = Recorder(url: file)
        let watcher = FileWatcher(url: file, queue: queue, onChange: rec.callback)
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(150))  // setup: force at least one retry
        try Data("late".utf8).write(to: file)
        // No callback for the initial attach, and no give-up callback either.
        #expect(await !rec.waitUntil(timeout: .milliseconds(700)) { $0.count > 0 })
        #expect(descriptors(to: file) == 1)
        try append(file, "!")
        #expect(await rec.waitUntil { $0.last == "late!" })
    }
}
