import AppKit
import TeleprompterCore

/// The menu-bar icon and its menu: the app's only visible control, since it has no Dock icon.
///
/// Why a separate type: it keeps menu construction out of the app delegate and exposes plain
/// closures, so later tasks can wire each item without touching the menu layout. Items with no
/// handler yet have no action, so AppKit shows them disabled rather than pretending to work.
@MainActor
final class StatusMenu: NSObject {
    /// Called when the user picks Show in Recordings (Test).
    var onToggleCaptureVisible: () -> Void = {}
    /// Called when the user picks Quit.
    var onQuit: () -> Void = {}

    private let statusItem: NSStatusItem
    private let captureItem = NSMenuItem(
        title: "Show in Recordings (Test)", action: nil, keyEquivalent: "")

    /// Creates the status item in the system menu bar and builds its menu.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.bubble", accessibilityDescription: "Teleprompter")
        statusItem.menu = buildMenu()
    }

    /// Shows a checkmark next to Show in Recordings while the panel is visible to capture, so the
    /// menu always tells the truth about whether the notes can be recorded.
    func setCaptureVisible(_ on: Bool) {
        captureItem.state = on ? .on : .off
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Placeholders until Tasks 7 and 10 wire them; nil actions render disabled.
        menu.addItem(NSMenuItem(title: "Edit Notes", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open…", action: nil, keyEquivalent: ""))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        menu.addItem(recent)
        menu.addItem(NSMenuItem(title: "Close File", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Larger Text", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Smaller Text", action: nil, keyEquivalent: ""))
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: "Opacity")
        for preset in Settings.opacityPresets {
            opacityMenu.addItem(
                NSMenuItem(title: "\(Int(preset * 100))%", action: nil, keyEquivalent: ""))
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        captureItem.action = #selector(toggleCaptureVisible)
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleCaptureVisible() { onToggleCaptureVisible() }

    @objc private func quit() { onQuit() }
}
