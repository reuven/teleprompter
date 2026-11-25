import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// The menu is the app's only control surface, so every decision about it (which items exist,
// their titles, whether they're enabled or checked, what they do) lives in MenuModel and is
// pinned here. StatusMenu only renders it.

private let talk = URL(fileURLWithPath: "/Users/me/Talks/talk.md")
private let otherTalk = URL(fileURLWithPath: "/Users/me/Old/talk.md")
private let notes = URL(fileURLWithPath: "/Users/me/notes.markdown")

@MainActor private func model(
    settings: Settings = Settings(),
    state: ModeState = .initial(hasNotes: true),
    source: NotesSource = .scratch,
    lastError: String? = nil,
    captureWarning: String? = nil,
    shortcutUnavailable: Bool = false,
    exists: @escaping (URL) -> Bool = { _ in true }
) -> MenuModel {
    MenuModel(
        settings: settings, modeState: state, source: source, lastError: lastError,
        captureWarning: captureWarning, shortcutUnavailable: shortcutUnavailable,
        fileExists: exists)
}

/// The top-level item titled `title`, or nil.
@MainActor private func item(_ title: String, in m: MenuModel) -> MenuItemModel? {
    for case .item(let i) in m.entries where i.title == title { return i }
    return nil
}

/// The submenu titled `title`: whether it's enabled and its items.
@MainActor private func submenu(_ title: String, in m: MenuModel) -> (Bool, [MenuItemModel])? {
    for case .submenu(let t, let enabled, let items) in m.entries where t == title {
        return (enabled, items)
    }
    return nil
}

@MainActor private func titles(_ m: MenuModel) -> [String] {
    m.entries.map {
        switch $0 {
        case .item(let i): i.title
        case .separator: "---"
        case .submenu(let t, _, _): "\(t) ▸"
        }
    }
}

@MainActor @Test func modeItemNamesTheActionItPerforms() {
    #expect(MenuModel.modeTitle(for: .recording) == "Edit Notes")
    #expect(MenuModel.modeTitle(for: .edit) == "Lock for Recording")
}

@MainActor @Test func plainMenuHasEveryItemInOrder() {
    let m = model()
    #expect(
        titles(m) == [
            "Edit Notes", "---", "Open…", "Open Recent ▸", "Close File", "---", "Larger Text",
            "Smaller Text", "Opacity ▸", "---", "Show in Recordings (Test)", "---", "Quit",
        ])
    #expect(m.iconSymbol == "text.bubble")
    #expect(item("Edit Notes", in: m)?.action == .toggleMode)
    #expect(item("Open…", in: m) == MenuItemModel("Open…", .open, key: "o"))
    #expect(item("Quit", in: m) == MenuItemModel("Quit", .quit, key: "q"))
    #expect(item("Larger Text", in: m)?.keyEquivalent == "+")
    #expect(item("Smaller Text", in: m)?.keyEquivalent == "-")
}

/// The warning is a different shape, not a tint: macOS 26's menu bar drew the red tint
/// almost black, invisible on a dark wallpaper, while an untinted symbol stays white like its
/// neighbors (and a shape doesn't rely on color vision). Both names must be real SF Symbols.
@MainActor @Test func iconSymbolsExist() {
    for symbol in [model().iconSymbol, model(lastError: "x").iconSymbol] {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
}

@MainActor @Test func openIsOfferedInBothModes() {
    var state = ModeState.initial(hasNotes: true)
    #expect(item("Open…", in: model(state: state))?.enabled == true)
    state.toggleMode()
    let m = model(state: state)
    #expect(item("Open…", in: m)?.enabled == true)
    #expect(item("Lock for Recording", in: m)?.action == .toggleMode)
}

@MainActor @Test func closeFileOnlyWhileAFileIsOpen() {
    #expect(item("Close File", in: model())?.enabled == false)
    #expect(item("Close File", in: model(source: .file(talk)))?.enabled == true)
    #expect(item("Close File", in: model(source: .file(talk)))?.action == .closeFile)
}

@MainActor @Test func errorLineAndDismissSitAtTheTopAndMarkTheIcon() {
    let m = model(lastError: "Couldn't open “x.md”: the file doesn't exist.")
    #expect(
        Array(titles(m).prefix(4)) == [
            "Couldn't open “x.md”: the file doesn't exist.", "Dismiss", "---", "Edit Notes",
        ])
    #expect(item("Couldn't open “x.md”: the file doesn't exist.", in: m)?.enabled == false)
    #expect(item("Dismiss", in: m)?.action == .dismissError)
    #expect(m.iconSymbol == "exclamationmark.bubble")
}

@MainActor @Test func captureWarningComesFirstAndHasNoDismiss() {
    let m = model(lastError: "file problem", captureWarning: "Notes may be visible")
    #expect(
        Array(titles(m).prefix(5)) == [
            "Notes may be visible", "file problem", "Dismiss", "---", "Edit Notes",
        ])
    #expect(item("Notes may be visible", in: m)?.enabled == false)
    #expect(model(captureWarning: "Notes may be visible").iconSymbol == "exclamationmark.bubble")
    #expect(item("Dismiss", in: model(captureWarning: "w")) == nil)
}

@MainActor @Test func shortcutUnavailableLineFollowsTheModeItem() {
    let m = model(shortcutUnavailable: true)
    #expect(Array(titles(m).prefix(2)) == ["Edit Notes", "Shortcut ⌃⌥⌘N unavailable"])
    #expect(item("Shortcut ⌃⌥⌘N unavailable", in: m)?.enabled == false)
}

@MainActor @Test func textSizeItemsDisableAtTheLimits() {
    let big = model(settings: Settings(fontSize: Settings.maxFontSize))
    #expect(item("Larger Text", in: big)?.enabled == false)
    #expect(item("Smaller Text", in: big)?.enabled == true)
    let small = model(settings: Settings(fontSize: Settings.minFontSize))
    #expect(item("Larger Text", in: small)?.enabled == true)
    #expect(item("Smaller Text", in: small)?.enabled == false)
    #expect(item("Larger Text", in: small)?.action == .largerText)
    #expect(item("Smaller Text", in: small)?.action == .smallerText)
}

@MainActor @Test func opacitySubmenuChecksTheCurrentPreset() throws {
    let (enabled, items) = try #require(
        submenu("Opacity", in: model(settings: Settings(opacity: 0.7))))
    #expect(enabled)
    #expect(items.map(\.title) == ["50%", "70%", "85%", "100%"])
    #expect(items.map(\.checked) == [false, true, false, false])
    #expect(items.map(\.action) == Settings.opacityPresets.map { .opacity($0) })
}

@MainActor @Test func captureTestItemIsCheckedWhileOn() {
    var state = ModeState.initial(hasNotes: true)
    #expect(item("Show in Recordings (Test)", in: model(state: state))?.checked == false)
    state.setCaptureVisible(true)
    let i = item("Show in Recordings (Test)", in: model(state: state))
    #expect(i?.checked == true && i?.action == .toggleCaptureVisible)
}

@MainActor @Test func openRecentListsRecentFilesAndDisablesMissingOnes() throws {
    var settings = Settings()
    settings.noteOpened(notes)
    settings.noteOpened(talk)
    let (enabled, items) = try #require(
        submenu("Open Recent", in: model(settings: settings, exists: { $0 == talk })))
    #expect(enabled)
    #expect(items.map(\.title) == ["talk.md", "notes.markdown"])
    #expect(items.map(\.action) == [.openRecent(talk), .openRecent(notes)])
    #expect(items.map(\.enabled) == [true, false])
}

@MainActor @Test func openRecentIsDisabledWhenEmpty() throws {
    let (enabled, items) = try #require(submenu("Open Recent", in: model()))
    #expect(!enabled && items.isEmpty)
}

@MainActor @Test func sameNamedRecentFilesShowTheirFolder() {
    #expect(
        MenuModel.displayNames(for: [talk, notes, otherTalk]) == [
            "talk.md — Talks", "notes.markdown", "talk.md — Old",
        ])
    #expect(MenuModel.displayNames(for: []) == [])
}

// MARK: Rendering

@MainActor private final class Receiver: NSObject {
    var picked: [MenuAction] = []
    @objc func pick(_ sender: NSMenuItem) {
        if let action = MenuModel.action(of: sender) { picked.append(action) }
    }
}

@MainActor @Test func rendersEntriesIntoAnExistingMenu() throws {
    var settings = Settings(opacity: 0.5)
    settings.noteOpened(talk)
    let m = model(settings: settings, source: .file(talk), lastError: "oops")
    let menu = NSMenu()
    menu.addItem(withTitle: "stale", action: nil, keyEquivalent: "")
    let receiver = Receiver()
    m.render(into: menu, target: receiver, action: #selector(Receiver.pick(_:)))

    #expect(!menu.autoenablesItems)
    #expect(
        menu.items.map(\.title)
            == titles(m).map { $0.replacingOccurrences(of: " ▸", with: "") }.map {
                $0 == "---" ? "" : $0
            })
    #expect(menu.items.filter(\.isSeparatorItem).count == 5, "four, plus one under the error")
    let error = try #require(menu.item(withTitle: "oops"))
    #expect(!error.isEnabled && error.action == nil)
    let open = try #require(menu.item(withTitle: "Open…"))
    #expect(open.keyEquivalent == "o" && open.isEnabled && open.target === receiver)
    let opacity = try #require(menu.item(withTitle: "Opacity")?.submenu)
    #expect(!opacity.autoenablesItems)
    #expect(opacity.items.map(\.state) == [.on, .off, .off, .off])
    let recent = try #require(menu.item(withTitle: "Open Recent"))
    #expect(recent.isEnabled && recent.submenu?.items.map(\.title) == ["talk.md"])

    // Picking an item reports its action, including ones in submenus.
    for picked in [
        open, opacity.items[2], recent.submenu!.items[0], menu.item(withTitle: "Dismiss")!,
    ] {
        _ = receiver.perform(picked.action!, with: picked)
    }
    #expect(receiver.picked == [.open, .opacity(0.85), .openRecent(talk), .dismissError])
    #expect(MenuModel.action(of: error) == nil)
}
