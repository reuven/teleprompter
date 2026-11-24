import AppKit
import Markdown

/// Visual parameters for rendering notes.
///
/// Everything the renderer draws derives from `fontSize`, so a shrink-to-fit pass can
/// re-render at several sizes and have headings, indents, and spacing scale together.
public struct NoteStyle: Sendable {
    /// Body text size in points; headings, indents, and spacing are multiples of it.
    public var fontSize: Double
    /// Foreground color for all text.
    public var textColor: NSColor

    /// Creates a style; white is the default because notes sit on a dark overlay.
    public init(fontSize: Double, textColor: NSColor = .white) {
        self.fontSize = fontSize
        self.textColor = textColor
    }
}

/// Turns Markdown notes into an `NSAttributedString` for the notes window.
///
/// Kept in Core and free of any view code so it can be tested headlessly and called
/// repeatedly (at different sizes) by the shrink-to-fit logic.
public enum MarkdownRenderer {
    /// Renders `markdown` using `style`.
    ///
    /// Use this whenever notes need displaying or measuring. Blocks are separated by a
    /// single newline (none trailing); unsupported constructs degrade to plain text.
    public static func render(_ markdown: String, style: NoteStyle) -> NSAttributedString {
        var builder = AttributedStringBuilder(style: style)
        builder.visit(Document(parsing: markdown))
        return builder.result
    }
}

/// Walks a Markdown tree, appending styled runs to `result`.
private struct AttributedStringBuilder: MarkupWalker {
    let style: NoteStyle
    let result = NSMutableAttributedString()
    private var traits: NSFontDescriptor.SymbolicTraits = []
    private var headingScale = 1.0
    private var monospaced = false
    private var paragraph: NSParagraphStyle
    private var tableRows = 0

    init(style: NoteStyle) {
        self.style = style
        paragraph = Self.makeParagraphStyle(style: style, depth: 0)
    }

    private static func makeParagraphStyle(style: NoteStyle, depth: Int) -> NSParagraphStyle {
        let indent = Double(depth) * 1.2 * style.fontSize
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 0.4 * style.fontSize
        p.headIndent = indent
        p.firstLineHeadIndent = max(0, indent - 1.2 * style.fontSize)
        p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        return p
    }

    private var font: NSFont {
        let size = style.fontSize * headingScale
        let base = NSFont.systemFont(ofSize: size)
        if monospaced { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(traits))
        // Falls back to the plain font if the traits can't be applied (never empty: `base`).
        return [NSFont(descriptor: descriptor, size: size), base].compactMap { $0 }[0]
    }

    private mutating func append(_ text: String) {
        result.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font, .foregroundColor: style.textColor, .paragraphStyle: paragraph,
                ]))
    }

    /// Starts a new block: one "\n" separator (styled like the previous text), none at the start.
    private mutating func startBlock() {
        guard result.length > 0 else { return }
        let last = result.attributes(at: result.length - 1, effectiveRange: nil)
        result.append(NSAttributedString(string: "\n", attributes: last))
    }

    private mutating func block(depth: Int, _ body: (inout Self) -> Void) {
        startBlock()
        let saved = paragraph
        paragraph = Self.makeParagraphStyle(style: style, depth: depth)
        body(&self)
        paragraph = saved
    }

    private func listDepth(of node: Markup) -> Int {
        sequence(first: node.parent, next: { $0?.parent }).compactMap { $0 as? ListItem }.count
    }

    mutating func visitParagraph(_ node: Paragraph) {
        // The first paragraph of a list item continues the bullet line.
        if node.parent is ListItem, node.indexInParent == 0 {
            descendInto(node)
        } else {
            block(depth: listDepth(of: node)) { $0.descendInto(node) }
        }
    }

    mutating func visitHeading(_ node: Heading) {
        headingScale = [1: 1.4, 2: 1.2][node.level] ?? 1.1
        traits.insert(.bold)
        block(depth: 0) { $0.descendInto(node) }
        traits.remove(.bold)
        headingScale = 1
    }

    mutating func visitListItem(_ node: ListItem) {
        let depth = listDepth(of: node) + 1
        let marker =
            (node.parent as? OrderedList).map { "\($0.startIndex + UInt(node.indexInParent))." }
            ?? "•"
        block(depth: depth) {
            $0.append(marker + "\t")
            $0.descendInto(node)
        }
    }

    mutating func visitStrong(_ node: Strong) {
        let had = traits.contains(.bold)
        traits.insert(.bold)
        descendInto(node)
        if !had { traits.remove(.bold) }
    }

    mutating func visitEmphasis(_ node: Emphasis) {
        let had = traits.contains(.italic)
        traits.insert(.italic)
        descendInto(node)
        if !had { traits.remove(.italic) }
    }

    mutating func visitInlineCode(_ node: InlineCode) {
        monospaced = true
        append(node.code)
        monospaced = false
    }

    mutating func visitText(_ node: Text) { append(node.string) }
    mutating func visitSoftBreak(_ node: SoftBreak) { append(" ") }
    mutating func visitLineBreak(_ node: LineBreak) { append("\n") }
    mutating func visitInlineHTML(_ node: InlineHTML) { append(node.rawHTML) }

    mutating func visitCodeBlock(_ node: CodeBlock) {
        block(depth: listDepth(of: node)) {
            $0.monospaced = true
            $0.append(node.code.trimmingCharacters(in: .newlines))
            $0.monospaced = false
        }
    }

    mutating func visitHTMLBlock(_ node: HTMLBlock) {
        block(depth: listDepth(of: node)) {
            $0.append(node.rawHTML.trimmingCharacters(in: .newlines))
        }
    }

    mutating func visitTable(_ node: Table) {
        startBlock()
        tableRows = 0
        descendInto(node)
    }

    mutating func visitTableHead(_ node: Table.Head) { tableRow(node) }
    mutating func visitTableRow(_ node: Table.Row) { tableRow(node) }

    private mutating func tableRow(_ node: Markup) {
        if tableRows > 0 { append("\n") }
        tableRows += 1
        descendInto(node)
    }

    mutating func visitTableCell(_ node: Table.Cell) {
        if node.indexInParent > 0 { append("\t") }
        descendInto(node)
    }
}
