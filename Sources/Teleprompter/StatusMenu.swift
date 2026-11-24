import AppKit
import TeleprompterCore

/// The menu-bar icon and its menu: the app's only visible control, since it has no Dock icon.
///
/// Why a separate, thin type: every decision about the menu lives in `MenuModel` (pure and
/// tested); this only owns the `NSStatusItem`, renders a model into it, tints the icon, and
/// reports picks through one closure.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    /// Called with the action of whichever item the user picks.
    var onAction: (MenuAction) -> Void = { _ in }
    /// Called just before the menu opens, so state that changes without an event (a recent file
    /// deleted in Finder) is current when the user looks.
    var onWillOpen: () -> Void = {}

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// Creates the status item in the system menu bar, with an empty menu until `render`.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.bubble", accessibilityDescription: "Teleprompter")
        menu.delegate = self
        statusItem.menu = menu
    }

    /// AppKit's hook for refreshing a menu just before it's shown.
    func menuNeedsUpdate(_ menu: NSMenu) { onWillOpen() }

    /// The menu-bar icon's own window, which `CaptureShield` and the stray-window check leave
    /// alone (by identity) so the icon behaves normally.
    var statusItemWindow: NSWindow? { statusItem.button?.window }

    /// Shows `model`: replaces the menu's items in place and tints the icon red while a warning
    /// or error is showing, so a problem is visible without opening the menu.
    func render(_ model: MenuModel) {
        model.render(into: menu, target: self, action: #selector(pick(_:)))
        statusItem.button?.contentTintColor = model.showsWarningTint ? .systemRed : nil
    }

    @objc private func pick(_ sender: NSMenuItem) {
        if let action = MenuModel.action(of: sender) { onAction(action) }
    }
}
