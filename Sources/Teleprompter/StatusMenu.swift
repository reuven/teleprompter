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
    /// Called when the user picks Edit Notes / Lock for Recording.
    var onToggleMode: () -> Void = {}
    /// Called when the user picks Quit.
    var onQuit: () -> Void = {}

    private let statusItem: NSStatusItem
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shortcutItem = NSMenuItem(
        title: "Shortcut ⌃⌥⌘N unavailable", action: nil, keyEquivalent: "")
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

    /// The mode item names the action it performs: the mode you'd switch to, not the current one.
    static func modeTitle(for mode: Mode) -> String {
        mode == .edit ? "Lock for Recording" : "Edit Notes"
    }

    /// Refreshes the mode item's title and the capture checkmark from `state`, so the menu always
    /// matches the panel after any change.
    func update(from state: ModeState) {
        modeItem.title = Self.modeTitle(for: state.mode)
        setCaptureVisible(state.captureVisible)
    }

    /// Puts `text` at the top of the menu (disabled) and tints the menu-bar icon red, so a failed
    /// hiding check is visible without opening anything.
    func showWarning(_ text: String) {
        warningItem.title = text
        warningItem.isHidden = false
        statusItem.button?.contentTintColor = .systemRed
    }

    /// Adds a disabled "Shortcut ⌃⌥⌘N unavailable" item under the mode item, so a shortcut that
    /// couldn't be registered (another app owns it) is visible instead of silently doing nothing.
    func showShortcutUnavailable() {
        shortcutItem.isHidden = false
    }

    /// Shows a checkmark next to Show in Recordings while the red test window is up, so the menu
    /// always tells the truth about whether a recordable window is on screen.
    func setCaptureVisible(_ on: Bool) {
        captureItem.state = on ? .on : .off
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        warningItem.isEnabled = false
        warningItem.isHidden = true
        menu.addItem(warningItem)
        modeItem.title = Self.modeTitle(for: .recording)
        modeItem.action = #selector(toggleMode)
        modeItem.target = self
        menu.addItem(modeItem)
        shortcutItem.isEnabled = false
        shortcutItem.isHidden = true
        menu.addItem(shortcutItem)
        // Placeholders until Tasks 7 and 10 wire them; nil actions render disabled.
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

    @objc private func toggleMode() { onToggleMode() }

    @objc private func toggleCaptureVisible() { onToggleCaptureVisible() }

    @objc private func quit() { onQuit() }
}
