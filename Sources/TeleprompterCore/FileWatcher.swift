import Foundation

/// Watches one file *path* and calls back when its contents may have changed, so edits
/// made in BBEdit, VS Code, or Vim show up live in the notes window.
///
/// Why not a plain file-descriptor watcher: many editors save by atomic replace (write a
/// temp file, rename it over the original). A descriptor follows the old inode, sees one
/// `.delete`/`.rename`, and then goes silent forever. On those events we drop the old
/// descriptor and reopen the path (retrying up to 10 × 50 ms, for editors that leave the
/// path briefly empty), then call `onChange` once the new file is being watched, so a
/// reader never misses the final content. If the file never comes back we deliver one
/// last `onChange` and stop; the reader's reread then finds the file missing, which is
/// how `NotesStore` learns it must fall back to scratch notes.
///
/// Events are not coalesced: an in-place write can produce several callbacks in a row,
/// and callers should compare content rather than assume one callback per save.
///
/// `@unchecked Sendable` is sound because the only stored property is an immutable
/// reference to an `Engine`, which documents and enforces its own locking.
public final class FileWatcher: @unchecked Sendable {
    private let engine: Engine

    /// Starts watching `url` immediately; `onChange` is delivered asynchronously on
    /// `queue` (main by default, which is what the main-actor `NotesStore` wants).
    ///
    /// Contract: `onChange` means "re-read the file now". It fires after any change,
    /// after an atomic replace once the new file is watched, and once after giving up on
    /// a vanished file (the read then finds it missing). Writes made between the caller's
    /// initial read and this `init` produce no callback, so read the file *after*
    /// creating the watcher.
    ///
    /// A file missing at start gets the same retry window as one that vanishes later: if
    /// it appears in time it is watched silently (no callback for the initial attach);
    /// otherwise the single give-up callback fires. That closes the race where the file
    /// is deleted between the caller's read and this `init`.
    public init(
        url: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void
    ) {
        engine = Engine(path: url.path, callbackQueue: queue, onChange: onChange)
        engine.start()
    }

    /// Stops watching. Idempotent, safe from any thread (including from inside
    /// `onChange`), and called from `deinit`.
    ///
    /// Once it returns, `onChange` will not be called again, even for a change that was
    /// already queued. If a callback is running on another thread at that moment, `stop()`
    /// waits for it to finish, which is what makes that promise hold. Don't call `stop()`
    /// from a thread that `onChange` synchronously waits on (`onChange` runs under the
    /// stop lock).
    public func stop() {
        engine.stop()
    }

    deinit {
        engine.stop()
    }
}

/// The watcher's working state, kept apart from `FileWatcher` so that blocks running on
/// queues capture this object rather than the public handle; the handle can then be
/// released (and its `deinit` stop the watch) while those blocks are still pending.
///
/// Concurrency invariants:
/// - `source` is touched only on `queue`, a private serial queue. All descriptor work
///   (open, attach, cancel, which closes the descriptor) happens there.
/// - `stopped` is guarded by `lock`, which is also held while `onChange` runs. A queue
///   cannot provide that: `stop()` must be callable synchronously from any thread and must
///   exclude an in-flight callback. The lock is recursive so `onChange` may call `stop()`.
private final class Engine: @unchecked Sendable {
    /// How many times to retry reopening the path after it vanishes, and how far apart.
    static let retries = 10
    static let retryDelay = DispatchTimeInterval.milliseconds(50)

    private let path: String
    private let callbackQueue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "TeleprompterCore.FileWatcher")
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var source: DispatchSourceFileSystemObject?

    init(path: String, callbackQueue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.callbackQueue = callbackQueue
        self.onChange = onChange
    }

    /// Attaches synchronously, so a write made right after `init` returns is seen. A missing
    /// file gets the usual retry window, without a callback if it shows up in time.
    func start() {
        queue.sync { attach(retriesLeft: Self.retries, notify: false) }
    }

    func stop() {
        lock.withLock { stopped = true }
        // Async: `stop()` may run from `deinit` on any thread, and must never wait on
        // `queue`. The `stopped` flag already blocks every later attach and delivery.
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Opens `path` and starts a dispatch source on it. Runs on `queue`.
    ///
    /// When the path is missing, it schedules itself again (without blocking any queue)
    /// until `retriesLeft` runs out, then gives up with one final callback so the caller
    /// rereads and finds the file gone. `notify` is true after a replace, so the caller
    /// rereads the file that is now being watched.
    private func attach(retriesLeft: Int, notify: Bool) {
        guard !isStopped else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
                    attach(retriesLeft: retriesLeft - 1, notify: notify)
                }
            } else {
                deliver()
            }
            return
        }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        // The handlers retain `self`; cancelling the source releases them, breaking the cycle.
        newSource.setEventHandler { [self, newSource] in handle(newSource.data) }
        newSource.setCancelHandler { close(fd) }
        source = newSource
        newSource.resume()
        if notify { deliver() }
    }

    /// Reacts to an event on the watched inode. Runs on `queue`.
    private func handle(_ event: DispatchSource.FileSystemEvent) {
        if event.isDisjoint(with: [.delete, .rename]) {
            deliver()
        } else {
            // The inode we hold is no longer the file at `path`: follow the path instead.
            source?.cancel()
            source = nil
            attach(retriesLeft: Self.retries, notify: true)
        }
    }

    /// Queues `onChange` on the caller's queue, rechecking `stopped` at delivery time so
    /// nothing is delivered after `stop()` returns, even if it was queued before.
    private func deliver() {
        callbackQueue.async { [self] in
            lock.withLock {
                if !stopped { onChange() }
            }
        }
    }
}
