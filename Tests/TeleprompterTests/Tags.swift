import Testing

extension Tag {
    /// Tests that need a window server (a logged-in GUI session): they create real windows, ask
    /// the window server about them, or register global hotkeys. They run by default. The tag
    /// marks them so a failure in a headless run (SSH, a CI runner without a session) is easy to
    /// recognize, and so tools that filter by tag (Xcode test plans) can leave them out. As of
    /// Swift 6.2, `swift test --filter`/`--skip` match test names, not tags.
    @Tag static var guiSession: Self
}
