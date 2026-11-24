import AppKit
import TeleprompterCore

/// What picking a menu item does. The app delegate handles each case in one place, so the menu
/// can't do anything the delegate doesn't know about.
enum MenuAction: Equatable {
    case toggleMode
    case open
    case openRecent(URL)
    case closeFile
    case largerText
    case smallerText
    case opacity(Double)
    case toggleCaptureVisible
    case dismissError
    case quit
}

/// One menu item as decided by `MenuModel`: what it says, what it does, and its state.
///
/// Why a value type: the menu's truthfulness (an item is enabled only when it would work, a
/// checkmark only when it's true) is the thing worth testing, and values compare in tests
/// without building an `NSMenu`.
struct MenuItemModel: Equatable {
    /// The item's text.
    let title: String
    /// What it does when picked; nil for an information line.
    let action: MenuAction?
    /// Whether it can be picked. Information lines are always disabled.
    let enabled: Bool
    /// Whether it shows a checkmark.
    let checked: Bool
    /// The ⌘ key shown next to it (only active while the menu is open), or "".
    let keyEquivalent: String

    /// An item; by default enabled, unchecked, with no key.
    init(
        _ title: String, _ action: MenuAction?, enabled: Bool = true, checked: Bool = false,
        key: String = ""
    ) {
        self.title = title
        self.action = action
        self.enabled = enabled && action != nil
        self.checked = checked
        self.keyEquivalent = key
    }

    /// A disabled line that only informs (an error or warning).
    static func info(_ title: String) -> MenuItemModel { MenuItemModel(title, nil) }
}

/// One top-level entry: an item, a separator, or a submenu of items.
enum MenuEntry: Equatable {
    case item(MenuItemModel)
    case separator
    case submenu(title: String, enabled: Bool, items: [MenuItemModel])
}

/// Every decision about the menu-bar menu, computed from the app's state: which items exist and
/// in what order, their titles, and which are enabled or checked; plus whether the menu-bar icon
/// shows the warning tint.
///
/// Why: `StatusMenu` must stay a thin renderer, so the menu's rules (Open offered in both modes,
/// Close File only with a file open, text size disabled at its limits, the error line and its
/// Dismiss item at the top, recent files named so same-named ones can be told apart) are pure
/// and fully tested here. Rebuilt from scratch after every change, so it can never go stale.
struct MenuModel: Equatable {
    /// The menu's entries, top to bottom.
    let entries: [MenuEntry]
    /// Whether the menu-bar icon is tinted: a capture warning or a notes error is showing.
    let showsWarningTint: Bool

    /// Builds the menu for this state.
    ///
    /// - `source`/`lastError`: the notes store's current source and error.
    /// - `captureWarning`: the sticky "notes may be visible" warning, if the check raised one.
    /// - `shortcutUnavailable`: ⌃⌥⌘N couldn't be registered.
    /// - `fileExists`: used to disable recent files that are gone, so picking one can't fail.
    init(
        settings: Settings, modeState: ModeState, source: NotesSource, lastError: String?,
        captureWarning: String?, shortcutUnavailable: Bool, fileExists: (URL) -> Bool
    ) {
        var entries: [MenuEntry] = []
        if let captureWarning { entries.append(.item(.info(captureWarning))) }
        if let lastError {
            entries.append(.item(.info(lastError)))
            entries.append(.item(MenuItemModel("Dismiss", .dismissError)))
        }
        if !entries.isEmpty { entries.append(.separator) }

        entries.append(.item(MenuItemModel(Self.modeTitle(for: modeState.mode), .toggleMode)))
        if shortcutUnavailable { entries.append(.item(.info("Shortcut ⌃⌥⌘N unavailable"))) }
        entries.append(.separator)

        let recents = zip(settings.recentFiles, Self.displayNames(for: settings.recentFiles)).map {
            url, name in MenuItemModel(name, .openRecent(url), enabled: fileExists(url))
        }
        entries.append(.item(MenuItemModel("Open…", .open, key: "o")))
        entries.append(.submenu(title: "Open Recent", enabled: !recents.isEmpty, items: recents))
        let fileOpen = if case .file = source { true } else { false }
        entries.append(.item(MenuItemModel("Close File", .closeFile, enabled: fileOpen)))
        entries.append(.separator)

        entries.append(
            .item(
                MenuItemModel(
                    "Larger Text", .largerText, enabled: settings.canMakeTextLarger, key: "+")))
        entries.append(
            .item(
                MenuItemModel(
                    "Smaller Text", .smallerText, enabled: settings.canMakeTextSmaller, key: "-")))
        let presets = Settings.opacityPresets.map { preset in
            MenuItemModel(
                "\(Int((preset * 100).rounded()))%", .opacity(preset),
                checked: preset == settings.opacity)
        }
        entries.append(.submenu(title: "Opacity", enabled: true, items: presets))
        entries.append(.separator)

        entries.append(
            .item(
                MenuItemModel(
                    "Show in Recordings (Test)", .toggleCaptureVisible,
                    checked: modeState.captureVisible)))
        entries.append(.separator)
        entries.append(.item(MenuItemModel("Quit", .quit, key: "q")))

        self.entries = entries
        showsWarningTint = captureWarning != nil || lastError != nil
    }

    /// The mode item names the action it performs: the mode you'd switch to, not the current one.
    static func modeTitle(for mode: Mode) -> String {
        mode == .edit ? "Lock for Recording" : "Edit Notes"
    }

    /// Menu titles for `urls`: the file name, plus " — <folder>" when another entry has the same
    /// name, so two `talk.md` files in different folders can be told apart.
    static func displayNames(for urls: [URL]) -> [String] {
        let names = urls.map(\.lastPathComponent)
        return zip(urls, names).map { url, name in
            names.filter { $0 == name }.count > 1
                ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)" : name
        }
    }

    /// Replaces `menu`'s items with these entries; every enabled item sends `action` to `target`.
    /// Reuses the same `NSMenu` so a menu that is open while state changes updates in place.
    ///
    /// Auto-enabling is off, so AppKit shows exactly the enabled state decided here.
    func render(into menu: NSMenu, target: AnyObject, action: Selector) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for entry in entries {
            switch entry {
            case .item(let model):
                menu.addItem(Self.makeItem(model, target: target, action: action))
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let enabled, let items):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                for model in items {
                    submenu.addItem(Self.makeItem(model, target: target, action: action))
                }
                item.submenu = submenu
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
    }

    /// The action a rendered item stands for, or nil for an information line.
    static func action(of item: NSMenuItem) -> MenuAction? {
        (item.representedObject as? ActionBox)?.action
    }

    private static func makeItem(_ model: MenuItemModel, target: AnyObject, action: Selector)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: model.keyEquivalent)
        if let menuAction = model.action {
            item.action = action
            item.target = target
            item.representedObject = ActionBox(menuAction)
        }
        item.isEnabled = model.enabled
        item.state = model.checked ? .on : .off
        return item
    }

    /// Carries a `MenuAction` in `NSMenuItem.representedObject`, which needs an object.
    private final class ActionBox: NSObject {
        let action: MenuAction
        init(_ action: MenuAction) { self.action = action }
    }
}
