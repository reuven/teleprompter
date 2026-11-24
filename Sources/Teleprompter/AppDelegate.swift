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

    /// Builds the panel and menu once AppKit is ready, places the panel, and shows it without
    /// activating the app, so launching never steals focus from the app being recorded.
    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        let panel = NotesPanel(settings: settings)
        panel.mode = modeState.mode
        panel.setFrame(launchFrame(), display: false)
        // Set after placement so the launch position isn't saved as if the user had moved it.
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel

        let menu = StatusMenu()
        menu.onToggleCaptureVisible = { [weak self] in self?.toggleCaptureVisible() }
        menu.onQuit = { NSApplication.shared.terminate(nil) }
        statusMenu = menu
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

    private func toggleCaptureVisible() {
        modeState.setCaptureVisible(!modeState.captureVisible)
        panel?.setCaptureVisible(modeState.captureVisible)
        statusMenu?.setCaptureVisible(modeState.captureVisible)
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
