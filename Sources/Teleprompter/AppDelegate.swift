import AppKit
import Carbon.HIToolbox
import TeleprompterCore

/// Owns the app's long-lived objects and connects them: settings, notes, mode, the notes panel,
/// the menu-bar menu, and the global shortcut.
///
/// Why: a menu-bar app has no document or main window to hang state on, so the delegate is the
/// single owner that applies the launch rules (placement under the camera, capture hidden) and
/// persists the window frame when the user moves or resizes it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settingsStore = SettingsStore(defaults: .standard)
    private var settings = Settings()
    // Replaced at launch from the notes: recording when there are notes to read, edit when empty.
    private var modeState = ModeState.initial(hasNotes: true)
    private var store: NotesStore?
    private var panel: NotesPanel?
    private var contentView: NotesContentView?
    // Nil when ⌃⌥⌘N couldn't be registered (another app owns it); the menu says so.
    private var hotKey: HotKey?
    // Keeps CaptureShield running after every event-loop pass.
    private var shield: CaptureShield.Handle?
    private var statusMenu: StatusMenu?
    // The recordable positive control; non-nil only while Show in Recordings (Test) is on.
    private var testWindow: CaptureTestWindow?
    // Every test window created this session, by number. A just-closed one can still be listed as
    // on screen when the check runs right after a toggle, and it's recordable by design, so the
    // stray-window check exempts it by identity rather than raising a false warning.
    private var testWindowNumbers: Set<Int> = []
    // The app the user was in when edit mode began; Lock for Recording hands focus back to it.
    private var appBeforeEdit: NSRunningApplication?

    /// Where scratch notes live: `~/Library/Application Support/Teleprompter/scratch.md`. The
    /// store creates the folder on the first save.
    static func scratchURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Teleprompter/scratch.md")
    }

    /// Loads the notes, builds the panel and menu once AppKit is ready, places the panel, and
    /// shows it without activating the app, so launching never steals focus from the app being
    /// recorded. Then registers ⌃⌥⌘N.
    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        shield = CaptureShield.start(center: .default) { [weak self] in
            self?.statusMenu?.statusItemWindow
        }
        let store = NotesStore(scratchURL: Self.scratchURL())
        self.store = store
        modeState = ModeState.initial(hasNotes: !store.text.isEmpty)
        let content = NotesContentView(
            store: store, maxFontSize: settings.fontSize, mode: modeState.mode, frame: .zero)
        store.onExternalChange = { [weak self] in self?.notesDidChange() }
        contentView = content

        let panel = NotesPanel(settings: settings, content: content)
        panel.setFrame(launchFrame(), display: false)
        // Set after placement so the launch position isn't saved as if the user had moved it.
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
        // Launching never takes focus: an empty-notes launch is in edit mode and clickable, but
        // keystrokes stay with the frontmost app until the user clicks the panel.
        panel.apply(modeState, takeFocus: false)
        content.mode = modeState.mode

        let menu = StatusMenu()
        menu.onToggleMode = { [weak self] in self?.toggleMode() }
        menu.onToggleCaptureVisible = { [weak self] in self?.toggleCaptureVisible() }
        menu.onQuit = { NSApplication.shared.terminate(nil) }
        menu.update(from: modeState)
        statusMenu = menu
        checkPanelHidden()

        // The same path as the menu item, so the shortcut can never do anything the menu doesn't.
        // kVK_ANSI_N is a physical key position (see HotKey), not the letter N on every layout.
        hotKey = HotKey(
            keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in self?.toggleMode() }
        if hotKey == nil { menu.showShortcutUnavailable() }
    }

    /// The one place that reacts when the notes changed from outside the app (another program
    /// edited the open file, or it vanished): the notes view re-renders at once.
    ///
    /// Task 10 extends this (for example, showing `store.lastError` in the menu). Its own
    /// `open`/`closeFile` calls don't fire `onExternalChange`, so it must call this after them.
    func notesDidChange() {
        contentView?.notesChanged()
    }

    /// Delays quitting until pending edits are written, so the last keystrokes before Quit are
    /// never lost to the save debounce.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task {
            await store.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Remembers the new position so the panel reopens where the user left it, and keeps the
    /// capture test box beside it.
    func windowDidMove(_ notification: Notification) { panelFrameChanged() }

    /// Remembers the new size so the panel reopens at the size the user chose, and keeps the
    /// capture test box beside it.
    func windowDidResize(_ notification: Notification) { panelFrameChanged() }

    private func panelFrameChanged() {
        guard let panel else { return }
        settings.windowFrame = panel.frame
        settingsStore.save(settings)
        testWindow?.follow(panel.frame, within: visibleFrame(of: panel))
    }

    // The panel's screen, so the test box lands on the same display; falls back to the main one.
    private func visibleFrame(of panel: NotesPanel) -> CGRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
    }

    // The one toggle path, for the menu item and ⌃⌥⌘N alike. ModeState decides (toggling also
    // turns the capture test off); the panel, menu and test window follow, then the notes view,
    // then the window-server check.
    private func toggleMode() {
        modeState.toggleMode()
        if modeState.mode == .edit {
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeEdit = front == NSRunningApplication.current ? nil : front
        }
        syncToState()
        contentView?.mode = modeState.mode
        if modeState.mode == .recording {
            // The non-activating panel normally leaves our app inactive; if something activated it
            // anyway, hand focus back so typing reaches the app being recorded.
            if NSApp.isActive { appBeforeEdit?.activate() }
            appBeforeEdit = nil
        }
        checkPanelHidden()
    }

    private func toggleCaptureVisible() {
        modeState.setCaptureVisible(!modeState.captureVisible)
        syncToState()
    }

    private func syncToState() {
        // Toggles come from the user (menu or ⌃⌥⌘N), so entering edit takes focus.
        panel?.apply(modeState, takeFocus: true)
        statusMenu?.update(from: modeState)
        syncTestWindow()
    }

    // A fresh window every time the test turns on, closed and released when it turns off, so a
    // recordable window is never reused or left on screen.
    private func syncTestWindow() {
        if modeState.captureVisible, testWindow == nil, let panel {
            let window = CaptureTestWindow(near: panel.frame, within: visibleFrame(of: panel))
            window.orderFrontRegardless()
            testWindow = window
            testWindowNumbers.insert(window.windowNumber)
        } else if !modeState.captureVisible {
            testWindow?.close()
            testWindow = nil
        }
    }

    // Asks the window server, not AppKit, whether the notes are hidden. A warning sticks until
    // relaunch: once the panel has been seen as recordable, it isn't trusted again.
    //
    // Runs the shield first, so helper windows created since the last event-loop pass are hidden,
    // then checks the panel and every other on-screen window of ours (bar the capture test window
    // and the status item's window, exempted by identity).
    private func checkPanelHidden() {
        guard let panel else { return }
        let statusItemWindow = statusMenu?.statusItemWindow
        CaptureShield.apply(to: NSApp.windows, statusItemWindow: statusItemWindow)
        let state = windowServerSharingState(windowNumber: panel.windowNumber)
        let allowed = testWindowNumbers.union([statusItemWindow?.windowNumber].compactMap { $0 })
        let warning =
            captureWarning(sharingState: state)
            ?? strayWindowWarning(windowServerWindows(ownedBy: getpid()), allowed: allowed)
        if let warning { statusMenu?.showWarning(warning) }
    }

    /// The saved frame if it still lands on a connected display, else the default under the
    /// camera. Screens are listed primary first, which is what `cameraScreen` falls back to.
    private func launchFrame() -> CGRect {
        let screens = NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            let id = (number as? NSNumber)?.uint32Value ?? 0
            return ScreenInfo(
                frame: screen.frame, visibleFrame: screen.visibleFrame,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
        if let saved = Placement.restoredFrame(saved: settings.windowFrame, screens: screens) {
            return saved
        }
        guard let camera = Placement.cameraScreen(screens) else {
            return CGRect(origin: .zero, size: Placement.defaultSize)
        }
        return Placement.defaultFrame(on: camera)
    }
}
