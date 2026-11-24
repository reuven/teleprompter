import AppKit
import Testing

@testable import TeleprompterCore

private let style = NoteStyle(fontSize: 20)

/// Font at the first occurrence of `substring`, so tests can assert per-run styling.
private func fontAt(_ s: NSAttributedString, _ substring: String) -> NSFont {
    let range = (s.string as NSString).range(of: substring)
    return s.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont
}

/// Paragraph style at the first occurrence of `substring`.
private func paragraphStyle(_ s: NSAttributedString, _ substring: String) -> NSParagraphStyle {
    let range = (s.string as NSString).range(of: substring)
    return s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as! NSParagraphStyle
}

@Suite struct MarkdownRendererTests {
    @Test func plainParagraph() {
        let r = MarkdownRenderer.render("Hello", style: style)
        #expect(r.string == "Hello" && fontAt(r, "Hello").pointSize == 20)
    }

    @Test func headingsScale() {
        let r = MarkdownRenderer.render("# Big\n\n## Mid\n\n### Small", style: style)
        #expect(fontAt(r, "Big").pointSize == 28 && fontAt(r, "Mid").pointSize == 24)
        #expect(fontAt(r, "Small").pointSize == 22)
        #expect(fontAt(r, "Big").fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func bulletsAndNesting() {
        let r = MarkdownRenderer.render("- a\n  - b", style: style)
        #expect(r.string.contains("•\ta") && r.string.contains("•\tb"))
        #expect(paragraphStyle(r, "b").headIndent > paragraphStyle(r, "a").headIndent)
        #expect(paragraphStyle(r, "b").headIndent == 2 * 1.2 * 20)
    }

    @Test func orderedListStartIndex() {
        let r = MarkdownRenderer.render("3. x\n4. y", style: style)
        #expect(r.string == "3.\tx\n4.\ty")
    }

    @Test func strongEmphasisCombine() {
        let r = MarkdownRenderer.render("***both***", style: style)
        let t = fontAt(r, "both").fontDescriptor.symbolicTraits
        #expect(t.contains(.bold) && t.contains(.italic))
    }

    @Test func strongAndEmphasisSeparately() {
        let r = MarkdownRenderer.render("**b** *i* plain", style: style)
        #expect(fontAt(r, "b").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!fontAt(r, "b").fontDescriptor.symbolicTraits.contains(.italic))
        #expect(fontAt(r, "i").fontDescriptor.symbolicTraits.contains(.italic))
        #expect(!fontAt(r, "plain").fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func inlineCodeIsMonospaced() {
        let r = MarkdownRenderer.render("use `ls`", style: style)
        #expect(fontAt(r, "ls").fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(fontAt(r, "ls").pointSize == 20)
    }

    @Test func linkShowsTextOnly() {
        #expect(MarkdownRenderer.render("[site](https://x.y)", style: style).string == "site")
    }

    @Test func imageShowsAltText() {
        #expect(MarkdownRenderer.render("![alt text](a.png)", style: style).string == "alt text")
    }

    @Test func emptyInput() {
        #expect(MarkdownRenderer.render("", style: style).length == 0)
    }

    @Test func usesTextColor() {
        let r = MarkdownRenderer.render("x", style: NoteStyle(fontSize: 20, textColor: .red))
        #expect(r.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .red)
    }

    @Test func defaultColorIsWhite() {
        #expect(NoteStyle(fontSize: 12).textColor == .white)
    }

    @Test func blocksSeparatedByOneNewlineNoTrailing() {
        let r = MarkdownRenderer.render("# H\n\npara one\n\npara two\n", style: style)
        #expect(r.string == "H\npara one\npara two")
        #expect(paragraphStyle(r, "para one").paragraphSpacing == 8)
    }

    @Test func softAndHardBreaks() {
        #expect(MarkdownRenderer.render("a\nb", style: style).string == "a b")
        #expect(MarkdownRenderer.render("a  \nb", style: style).string == "a\nb")
    }

    @Test func codeBlockShowsPlainText() {
        let r = MarkdownRenderer.render("before\n\n```\nlet x = 1\n```\n\nafter", style: style)
        #expect(r.string == "before\nlet x = 1\nafter")
    }

    @Test func htmlShowsPlainText() {
        #expect(MarkdownRenderer.render("<div>hi</div>", style: style).string == "<div>hi</div>")
        #expect(MarkdownRenderer.render("a <b>c", style: style).string == "a <b>c")
    }

    @Test func tableCellsTabSeparatedRowsNewline() {
        let md = "| a | b |\n|---|---|\n| c | d |\n| e | f |"
        #expect(MarkdownRenderer.render(md, style: style).string == "a\tb\nc\td\ne\tf")
    }

    @Test func multiParagraphListItem() {
        let r = MarkdownRenderer.render("- one\n\n  two\n\n- three", style: style)
        #expect(r.string == "•\tone\ntwo\n•\tthree")
    }

    @Test func blockquoteAndThematicBreak() {
        let r = MarkdownRenderer.render("> quoted\n\n---\n\nend", style: style)
        #expect(r.string == "quoted\nend")
    }

    @Test func scalesWithFontSize() {
        let r = MarkdownRenderer.render("# H\n\n- a\n  - b", style: NoteStyle(fontSize: 40))
        #expect(fontAt(r, "H").pointSize == 56)
        #expect(paragraphStyle(r, "b").headIndent == 2 * 1.2 * 40)
        #expect(paragraphStyle(r, "b").paragraphSpacing == 16)
    }

    @Test func inlineCodeKeepsBoldInHeadingAndStrong() {
        let h = MarkdownRenderer.render("# Run `ls`", style: style)
        let ht = fontAt(h, "ls").fontDescriptor.symbolicTraits
        #expect(ht.contains(.monoSpace) && ht.contains(.bold))
        let s = MarkdownRenderer.render("**`x`**", style: style)
        let st = fontAt(s, "x").fontDescriptor.symbolicTraits
        #expect(st.contains(.monoSpace) && st.contains(.bold))
    }

    @Test func onlyBulletLineIsOutdented() {
        let a = MarkdownRenderer.render("- a\n\n  more", style: style)
        #expect(paragraphStyle(a, "•").firstLineHeadIndent < paragraphStyle(a, "•").headIndent)
        let more = paragraphStyle(a, "more")
        #expect(more.firstLineHeadIndent == more.headIndent)
        let b = MarkdownRenderer.render("- line one  \nline two", style: style)
        let two = paragraphStyle(b, "line two")
        #expect(two.firstLineHeadIndent == two.headIndent && two.headIndent > 0)
    }
}
