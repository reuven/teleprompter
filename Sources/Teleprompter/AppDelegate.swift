import AppKit
import Carbon.HIToolbox
import TeleprompterCore

/// Owns the app's long-lived objects and connects them: settings, notes, mode, the notes panel,
/// the menu-bar menu, and the global shortcut.
///
/// Why: a menu-bar app has no document or main window to hang state on, so the delegate is the
/// single owner that applies the launch rules (reopen the last file, placement under the camera,
/// capture hidden), carries out every menu action, and persists settings: the window frame when
/// a move or resize settles and on quit, font size and opacity on change, the last file and
/// recent files on open and close. The capture test is never persisted.
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
    // The latest capture warning; sticky until relaunch (see checkPanelHidden).
    private var captureWarningText: String?
    private var shortcutUnavailable = false
    // Saves the frame once a move or resize settles; ignores moves caused by display changes.
    private lazy var frameSaver = FrameSaver(
        delay: .milliseconds(500), quietAfterScreenChange: .seconds(1)
    ) { [weak self] in self?.saveFrame() }
    private var screenObserver: NSObjectProtocol?

    /// Where scratch notes live: `~/Library/Application Support/Teleprompter/scratch.md`. The
    /// store creates the folder on the first save.
    static func scratchURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Teleprompter/scratch.md")
    }

    /// Loads the notes (reopening the last file if it still exists), builds the panel and menu
    /// once AppKit is ready, places the panel (the saved frame if it's still on a display), and
    /// shows it without activating the app, so launching never steals focus from the app being
    /// recorded. Then registers ⌃⌥⌘N.
    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        shield = CaptureShield.start(center: .default) { [weak self] in
            self?.statusMenu?.statusItemWindow
        }
        let store = NotesStore(scratchURL: Self.scratchURL())
        // The last file only if it's still there; otherwise scratch, quietly.
        // A folder or unreadable file at that path counts as gone.
        if let url = settings.launchFile(exists: NotesStore.isOpenableFile) { store.open(url) }
        self.store = store
        recordSource()
        modeState = ModeState.initial(hasNotes: !store.text.isEmpty)
        let content = NotesContentView(
            store: store, maxFontSize: settings.fontSize, mode: modeState.mode, frame: .zero)
        store.onExternalChange = { [weak self] in self?.notesDidChange() }
        store.onErrorChange = { [weak self] in self?.refreshMenu() }
        contentView = content

        let panel = NotesPanel(settings: settings, content: content)
        panel.setFrame(launchFrame(), display: false)
        // Set after placement so the launch position isn't saved as if the user had moved it.
        panel.delegate = self
        panel.onTextSizeStep = { [weak self] in self?.stepTextSize($0) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameSaver.screenParametersChanged() }
        }
        panel.orderFrontRegardless()
        self.panel = panel
        // Launching never takes focus: an empty-notes launch is in edit mode and clickable, but
        // keystrokes stay with the frontmost app until the user clicks the panel.
        panel.apply(modeState, takeFocus: false)
        content.mode = modeState.mode

        let menu = StatusMenu()
        menu.onAction = { [weak self] in self?.perform($0) }
        menu.onWillOpen = { [weak self] in self?.refreshMenu() }
        statusMenu = menu
        refreshMenu()
        checkPanelHidden()

        // The same path as the menu item, so the shortcut can never do anything the menu doesn't.
        // kVK_ANSI_N is a physical key position (see HotKey), not the letter N on every layout.
        hotKey = HotKey(
            keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in self?.toggleMode() }
        if hotKey == nil {
            shortcutUnavailable = true
            refreshMenu()
        }
    }

    /// The one place that reacts when the notes or their source changed: from outside the app
    /// (another program edited the open file, or it vanished) via `onExternalChange`, or after
    /// the app's own `open`/`closeFile`, which don't fire that callback, so every caller of
    /// those calls this. The notes view re-renders at once, the last file and recent files
    /// follow the store's source, and the menu is rebuilt.
    func notesDidChange() {
        contentView?.notesChanged()
        recordSource()
        refreshMenu()
    }

    /// Carries out a menu pick. The one dispatch point for the menu, so every item's effect is
    /// listed here.
    func perform(_ action: MenuAction) {
        switch action {
        case .toggleMode: toggleMode()
        case .open: chooseFile()
        case .openRecent(let url): openFile(url)
        case .closeFile:
            store?.closeFile()
            notesDidChange()
        case .largerText: stepTextSize(1)
        case .smallerText: stepTextSize(-1)
        case .opacity(let value): setOpacity(value)
        case .toggleCaptureVisible: toggleCaptureVisible()
        case .dismissError: store?.dismissError()  // onErrorChange rebuilds the menu.
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    /// Writes pending edits before quitting, so the last keystrokes before Quit are never lost to
    /// the save debounce.
    ///
    /// Also saves the panel's frame now if a move or resize is still waiting out the save delay.
    /// Only then: an untouched launch position isn't saved as if the user had chosen it.
    ///
    /// If notes still couldn't be written after that, asks first (see `QuitDecision`): Cancel,
    /// the default, keeps the app running with the notes still in memory.
    ///
    /// Answered directly, with no `Task` and no `.terminateLater`: the save is synchronous, so
    /// there is nothing to wait for, and a deferred reply would leave AppKit in its modal
    /// "terminating" state while a task waited for its turn on the main actor.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        frameSaver.flush()
        guard let store else { return .terminateNow }
        store.flush()
        let previous = FocusReturn.previousApp(front: NSWorkspace.shared.frontmostApplication)
        let quit = QuitDecision.shouldQuit(hasUnsavedChanges: store.hasUnsavedChanges) {
            // The alert must be in front to be answered, so the app activates for it.
            NSApp.activate()
            return QuitDecision.makeAlert(detail: store.unsavedChangesReason).runModal()
        }
        // Staying open after Cancel: focus goes back as after any modal.
        if !quit { returnFocus(to: previous) }
        return quit ? .terminateNow : .terminateCancel
    }

    /// Remembers the new position so the panel reopens where the user left it, and keeps the
    /// capture test box beside it.
    func windowDidMove(_ notification: Notification) { panelFrameChanged() }

    /// Remembers the new size so the panel reopens at the size the user chose, and keeps the
    /// capture test box beside it.
    func windowDidResize(_ notification: Notification) { panelFrameChanged() }

    private func panelFrameChanged() {
        guard let panel else { return }
        testWindow?.follow(panel.frame, within: visibleFrame(of: panel))
        frameSaver.frameChanged()
    }

    private func saveFrame() {
        guard let panel else { return }
        settings.windowFrame = panel.frame
        settingsStore.save(settings)
    }

    // Rebuilds the menu from the current state; cheap, so it's called after every change.
    private func refreshMenu() {
        guard let store, let statusMenu else { return }
        statusMenu.render(
            MenuModel(
                settings: settings, modeState: modeState, source: store.source,
                lastError: store.lastError, captureWarning: captureWarningText,
                shortcutUnavailable: shortcutUnavailable,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }))
    }

    // Makes the last file and recent files match what the store is showing: an opened file
    // becomes the most recent; scratch (after Close File, a vanished file, or a failed reopen
    // at launch) clears the last file so the next launch doesn't try it again.
    private func recordSource() {
        guard let store else { return }
        let url: URL? = if case .file(let url) = store.source { url } else { nil }
        // Settings keep URLs canonical, so compare in that form.
        guard url.map(Settings.canonical) != settings.lastFileURL else { return }
        if let url { settings.noteOpened(url) } else { settings.lastFileURL = nil }
        settingsStore.save(settings)
    }

    private func openFile(_ url: URL) {
        store?.open(url)
        notesDidChange()
    }

    /// Runs the Open… dialog and opens the chosen file.
    ///
    /// The dialog is modal and necessarily activates the app (an inactive app's dialog can't
    /// take typing). In recording mode, focus is handed back afterwards to the app that was
    /// frontmost, as Lock for Recording does, so recording mode never keeps focus; in edit mode
    /// the notes panel takes key focus again. The dialog may itself be recorded: see
    /// `NotesFileChooser` for why that is accepted.
    private func chooseFile() {
        let previous = FocusReturn.previousApp(front: NSWorkspace.shared.frontmostApplication)
        let chooser = NotesFileChooser()
        let dialog = NSOpenPanel()
        chooser.configure(dialog)
        NSApp.activate()
        // Ordered front explicitly too: if activation is refused, it must not open behind.
        dialog.orderFrontRegardless()
        let response = withExtendedLifetime(chooser) { dialog.runModal() }
        if response == .OK, let url = dialog.url { openFile(url) }
        returnFocus(to: previous)
    }

    // After a modal activated the app; see FocusReturn for the rule.
    private func returnFocus(to previous: NSRunningApplication?) {
        switch FocusReturn.after(
            mode: modeState.mode, appIsActive: NSApp.isActive, previous: previous)
        {
        case .reactivate(let app): app.activate()
        case .makePanelKey: panel?.makeKey()
        case .none: break
        }
    }

    // Larger/Smaller Text and ⌘+/⌘−: the editor font and the reader's fit follow at once.
    private func stepTextSize(_ steps: Int) {
        settings.stepFontSize(steps)
        settingsStore.save(settings)
        contentView?.maxFontSize = settings.fontSize
        refreshMenu()
    }

    private func setOpacity(_ value: Double) {
        settings.opacity = value
        settingsStore.save(settings)
        panel?.setOpacity(settings.opacity)
        refreshMenu()
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
        refreshMenu()
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
        if let warning {
            captureWarningText = warning
            refreshMenu()
        }
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
