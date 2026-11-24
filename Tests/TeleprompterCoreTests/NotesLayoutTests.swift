import AppKit
import Testing

@testable import TeleprompterCore

private let box = CGSize(width: 600, height: 180)

// Edit mode shows raw Markdown at a fixed, readable size derived from the user's size:
// max(18, fontSize × 0.6). Known answers, worked by hand.

@Test func editorFontIsSixtyPercentOfUserSize() {
    #expect(EditorStyle.fontSize(forMaxFontSize: 32) == 32 * 0.6)
    #expect(EditorStyle.fontSize(forMaxFontSize: 120) == 72)
}

@Test func editorFontNeverBelowEighteen() {
    #expect(EditorStyle.fontSize(forMaxFontSize: 14) == 18)
    #expect(EditorStyle.fontSize(forMaxFontSize: 30) == 18)
}

@Test func editorFontIsMonospaced() {
    let font = EditorStyle.font(forMaxFontSize: 40)
    #expect(font.pointSize == 24)
    #expect(font.isFixedPitch)
}

// Recording mode: fit from the user's maximum, render at the fitted size, badge on overflow.

@Test @MainActor func shortNotesRenderAtUserSizeWithoutBadge() {
    let layout = RecordingLayout("# Hi\n\n- one", maxFontSize: 40, in: box)
    #expect(layout.fontSize == 40 && !layout.showsMoreBelow)
    let expected = MarkdownRenderer.render("# Hi\n\n- one", style: NoteStyle(fontSize: 40))
    #expect(layout.text.isEqual(to: expected))
}

@Test @MainActor func longNotesShrinkToTheFittedSize() {
    let md = (1...8).map { "- point number \($0)" }.joined(separator: "\n")
    let layout = RecordingLayout(md, maxFontSize: 60, in: box)
    let fit = TextFitter.fit(md, maxFontSize: 60, in: box)
    #expect(layout.fontSize == fit.fontSize && layout.fontSize < 60 && !layout.showsMoreBelow)
    #expect(
        layout.text.isEqual(
            to: MarkdownRenderer.render(md, style: NoteStyle(fontSize: fit.fontSize))))
}

@Test @MainActor func overflowAtTheFloorShowsTheBadge() {
    let md = (1...200).map { "- bullet \($0)" }.joined(separator: "\n")
    let layout = RecordingLayout(md, maxFontSize: 40, in: box)
    #expect(layout.fontSize == Settings.minFontSize && layout.showsMoreBelow)
}

@Test @MainActor func growsBackWhenTheBoxGrows() {
    // Fitting always starts from the user's maximum, so a larger box gives larger text again.
    let md = (1...8).map { "- point number \($0)" }.joined(separator: "\n")
    let small = RecordingLayout(md, maxFontSize: 60, in: box)
    let large = RecordingLayout(md, maxFontSize: 60, in: CGSize(width: 1600, height: 1200))
    #expect(small.fontSize < 60 && large.fontSize == 60)
}

@Test @MainActor func badgeText() {
    #expect(RecordingLayout.moreBelowText == "▼ more below")
}
