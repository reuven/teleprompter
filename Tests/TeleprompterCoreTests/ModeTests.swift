import Testing

@testable import TeleprompterCore

@Test func startsInRecordingWhenNotesExist() {
    #expect(ModeState.initial(hasNotes: true).mode == .recording)
}

@Test func startsInEditWhenEmpty() {
    #expect(ModeState.initial(hasNotes: false).mode == .edit)
}

@Test func neverStartsVisibleToCapture() {
    #expect(ModeState.initial(hasNotes: true).captureVisible == false)
    #expect(ModeState.initial(hasNotes: false).captureVisible == false)
}

@Test func toggleFlipsMode() {
    var s = ModeState.initial(hasNotes: true)
    s.toggleMode()
    #expect(s.mode == .edit)
    s.toggleMode()
    #expect(s.mode == .recording)
}

@Test func toggleTurnsCaptureCheckOff() {
    var s = ModeState.initial(hasNotes: true)
    s.setCaptureVisible(true)
    #expect(s.captureVisible)
    s.toggleMode()
    #expect(s.captureVisible == false)
}
