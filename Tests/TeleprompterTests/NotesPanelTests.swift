import AppKit
import TeleprompterCore
import Testing

@testable import Teleprompter

// These pin the anti-goals: the panel must stay out of screen recordings, and in recording mode
// it must never take clicks or focus. None of them needs a visible window.

@MainActor @Test func newPanelIsHiddenFromCapture() {
    #expect(NotesPanel(settings: Settings()).sharingType == .none)
}

@MainActor @Test func recordingModeIgnoresClicksAndFocus() {
    let p = NotesPanel(settings: Settings())
    p.mode = .recording
    #expect(p.ignoresMouseEvents && !p.canBecomeKey && !p.canBecomeMain)
}

@MainActor @Test func editModeAcceptsClicksAndFocus() {
    let p = NotesPanel(settings: Settings())
    p.mode = .edit
    #expect(!p.ignoresMouseEvents && p.canBecomeKey)
}

@MainActor @Test func captureCheckTogglesSharing() {
    let p = NotesPanel(settings: Settings())
    p.setCaptureVisible(true)
    #expect(p.sharingType == .readOnly)
    p.setCaptureVisible(false)
    #expect(p.sharingType == .none)
}

@MainActor @Test func panelIsNonActivatingAndOnAllSpaces() {
    let p = NotesPanel(settings: Settings())
    #expect(p.styleMask.contains(.nonactivatingPanel))
    #expect(
        p.collectionBehavior.contains(.canJoinAllSpaces)
            && p.collectionBehavior.contains(.fullScreenAuxiliary))
}

@MainActor @Test func opacityFromSettings() {
    #expect(NotesPanel(settings: Settings(opacity: 0.5)).backgroundAlpha == 0.5)
}

@MainActor @Test func captureCheckShowsRedBorderAndLabel() {
    let p = NotesPanel(settings: Settings())
    #expect(p.captureLabel.isHidden && p.backgroundView.layer?.borderWidth == 0)
    p.setCaptureVisible(true)
    #expect(!p.captureLabel.isHidden && p.backgroundView.layer?.borderWidth == 4)
    p.setCaptureVisible(false)
    #expect(p.captureLabel.isHidden && p.backgroundView.layer?.borderWidth == 0)
}

@MainActor @Test func panelFloatsAndStaysPut() {
    let p = NotesPanel(settings: Settings())
    #expect(p.level == .floating && !p.hidesOnDeactivate && p.isMovableByWindowBackground)
    #expect(p.collectionBehavior.contains(.stationary) && !p.canBecomeMain)
    #expect(p.styleMask.contains(.borderless) && p.styleMask.contains(.resizable))
}

@MainActor @Test func showsSampleTextAtSettingsFontSize() {
    let p = NotesPanel(settings: Settings(fontSize: 40))
    #expect(p.textLabel.stringValue == NotesPanel.sampleText)
    #expect(p.textLabel.font?.pointSize == 40 && p.textLabel.textColor == .white)
}
