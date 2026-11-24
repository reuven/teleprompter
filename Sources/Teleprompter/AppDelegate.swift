import AppKit
import TeleprompterCore

/// Owns the app's long-lived objects and connects them: settings, mode, the notes panel, and the
/// menu-bar menu.
///
/// Why: a menu-bar app has no document or main window to hang state on, so the delegate is the
/// single owner that applies the launch rules (placement under the camera, capture hidden) and
/// persists the window frame when the user moves or resizes it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settingsStore = SettingsStore(defaults: .standard)
    private var settings = Settings()
    // Sample text counts as notes, so launch starts in recording mode, as it will with a file.
    private var modeState = ModeState.initial(hasNotes: true)
    private var panel: NotesPanel?
    private var statusMenu: StatusMenu?
    // The recordable positive control; non-nil only while Show in Recordings (Test) is on.
    private var testWindow: CaptureTestWindow?

    /// Builds the panel and menu once AppKit is ready, places the panel, and shows it without
    /// activating the app, so launching never steals focus from the app being recorded.
    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        let panel = NotesPanel(settings: settings)
        panel.apply(modeState)
        panel.setFrame(launchFrame(), display: false)
        // Set after placement so the launch position isn't saved as if the user had moved it.
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel

        let menu = StatusMenu()
        menu.onToggleMode = { [weak self] in self?.toggleMode() }
        menu.onToggleCaptureVisible = { [weak self] in self?.toggleCaptureVisible() }
        menu.onQuit = { NSApplication.shared.terminate(nil) }
        menu.update(from: modeState)
        statusMenu = menu
        checkPanelHidden()
    }

    /// Remembers the new position so the panel reopens where the user left it.
    func windowDidMove(_ notification: Notification) { saveFrame() }

    /// Remembers the new size so the panel reopens at the size the user chose.
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let panel else { return }
        settings.windowFrame = panel.frame
        settingsStore.save(settings)
    }

    // ModeState decides (toggling mode also clears the capture check); panel and menu follow.
    private func toggleMode() {
        modeState.toggleMode()
        syncToState()
        checkPanelHidden()
    }

    private func toggleCaptureVisible() {
        modeState.setCaptureVisible(!modeState.captureVisible)
        syncToState()
    }

    private func syncToState() {
        panel?.apply(modeState)
        statusMenu?.update(from: modeState)
        syncTestWindow()
    }

    // A fresh window every time the test turns on, closed and released when it turns off, so a
    // recordable window is never reused or left on screen.
    private func syncTestWindow() {
        if modeState.captureVisible, testWindow == nil, let panel {
            let window = CaptureTestWindow(below: panel.frame)
            window.orderFrontRegardless()
            testWindow = window
        } else if !modeState.captureVisible {
            testWindow?.close()
            testWindow = nil
        }
    }

    // Asks the window server, not AppKit, whether the notes are hidden. A warning sticks until
    // relaunch: once the panel has been seen as recordable, it isn't trusted again.
    private func checkPanelHidden() {
        guard let panel else { return }
        let state = windowServerSharingState(windowNumber: panel.windowNumber)
        if let warning = captureWarning(sharingState: state) {
            statusMenu?.showWarning(warning)
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
