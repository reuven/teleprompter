import AppKit

/// Decides whether the app may quit once pending saves have been tried, and builds the question
/// it asks when they failed.
///
/// Why: quitting with notes that couldn't be written (a locked file, a full disk) would lose
/// them without a word. With unsaved changes the user is asked, and the default answer, the
/// one Return gives, is the safe one: Cancel.
enum QuitDecision {
    /// True to quit. Asks (through `askUser`, which runs the alert) only when
    /// `hasUnsavedChanges`; only "Quit Anyway" (the second button) quits then.
    @MainActor static func shouldQuit(
        hasUnsavedChanges: Bool, askUser: () -> NSApplication.ModalResponse
    ) -> Bool {
        guard hasUnsavedChanges else { return true }
        return askUser() == .alertSecondButtonReturn
    }

    /// The warning shown before quitting with unsaved notes; `detail` is the store's last error,
    /// which names what couldn't be saved.
    @MainActor static func makeAlert(detail: String?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your notes couldn't be saved"
        alert.informativeText =
            detail ?? "Some changes haven't been written to disk and will be lost if you quit."
        // Set explicitly: Return must cancel, never quit, whatever NSAlert would pick.
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Quit Anyway").keyEquivalent = ""
        return alert
    }
}
