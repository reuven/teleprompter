import AppKit

// Kept minimal: tests link this target with a renamed entry point, so nothing here runs under
// `swift test`. Accessory policy hides the Dock icon even when run outside the bundle (`swift run`),
// where Info.plist's LSUIElement doesn't apply.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
