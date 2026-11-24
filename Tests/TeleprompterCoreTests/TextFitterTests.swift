import AppKit
import PropertyBased
import Testing

@testable import TeleprompterCore

private let box = CGSize(width: 600, height: 180)

/// Measured height, rounded up exactly as the fitter does, for independent verification.
private func height(_ md: String, _ size: Double, _ width: Double) -> Double {
    MarkdownRenderer.render(md, style: NoteStyle(fontSize: size))
        .boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height.rounded(.up)
}

@Test func shortNoteUsesMax() {
    #expect(
        TextFitter.fit("Hi", maxFontSize: 40, in: box) == FitResult(fontSize: 40, overflows: false))
}
@Test func emptyUsesMax() {
    #expect(
        TextFitter.fit("", maxFontSize: 40, in: box) == FitResult(fontSize: 40, overflows: false))
}
@Test func longNoteShrinks() {
    let md = (1...8).map { "- point number \($0)" }.joined(separator: "\n")
    let r = TextFitter.fit(md, maxFontSize: 60, in: box)
    #expect(r.fontSize < 60 && r.fontSize >= 14 && !r.overflows)
    #expect(height(md, r.fontSize, box.width) <= box.height)
    #expect(height(md, r.fontSize + 1, box.width) > box.height)
}
@Test func hugeNoteOverflowsAtFloor() {
    let md = (1...200).map { "- bullet \($0)" }.joined(separator: "\n")
    #expect(
        TextFitter.fit(md, maxFontSize: 40, in: box) == FitResult(fontSize: 14, overflows: true))
}
@Test func longUnbrokenWordNeverBelowFloor() {
    let r = TextFitter.fit(String(repeating: "x", count: 500), maxFontSize: 40, in: box)
    #expect(r.fontSize >= 14)
}
@Test func maxBelowFloorTreatedAsFloor() {
    #expect(TextFitter.fit("Hi", maxFontSize: 5, in: box).fontSize == 14)
}
@Test func fractionalMaxRoundsDown() {
    #expect(TextFitter.fit("Hi", maxFontSize: 40.9, in: box).fontSize == 40)
}
@Test func badMaxIsFloor() {
    for m in [Double.nan, -Double.infinity, -3, 0] {
        #expect(TextFitter.fit("Hi", maxFontSize: m, in: box).fontSize == 14)
    }
}
@Test func infiniteMaxIsFloor() {
    #expect(TextFitter.fit("Hi", maxFontSize: Double.infinity, in: box).fontSize == 14)
}
@Test func hugeFiniteMaxIsCapped() {
    #expect(
        TextFitter.fit("Hi", maxFontSize: 1e300, in: CGSize(width: 5000, height: 5000)).fontSize
            == 120)
}
@Test func degenerateBoxOverflowsAtFloor() {
    let bad = [
        CGSize(width: 0, height: 100), CGSize(width: 100, height: 0),
        CGSize(width: -5, height: 100), CGSize(width: 100, height: CGFloat.nan),
        CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.infinity),
    ]
    for b in bad {
        #expect(
            TextFitter.fit("Hi", maxFontSize: 40, in: b) == FitResult(fontSize: 14, overflows: true)
        )
    }
}
@Test func emptyAlwaysFitsEvenInDegenerateBox() {
    #expect(
        TextFitter.fit("", maxFontSize: 40, in: CGSize(width: 0, height: CGFloat.nan))
            == FitResult(fontSize: 40, overflows: false))
}

private let markdownGen = Gen.character(in: "a"..."z")
    .string(of: 0...60).map { "- " + $0 }.array(of: 0...30)
    .map { $0.joined(separator: "\n") }

@Test func fitIsWithinBounds() async {
    await propertyCheck(
        count: 50, input: markdownGen, Gen.double(in: 1...120), Gen.double(in: 100...1200),
        Gen.double(in: 50...600)
    ) { md, m, w, h in
        let r = TextFitter.fit(md, maxFontSize: m, in: CGSize(width: w, height: h))
        #expect(r.fontSize >= 14 && r.fontSize <= max(14, m.rounded(.down)))
    }
}
@Test func fitMeansItFits() async {
    await propertyCheck(
        count: 50, input: markdownGen, Gen.double(in: 1...120), Gen.double(in: 100...1200),
        Gen.double(in: 50...600)
    ) { md, m, w, h in
        let r = TextFitter.fit(md, maxFontSize: m, in: CGSize(width: w, height: h))
        if !r.overflows { #expect(height(md, r.fontSize, w) <= h) }
    }
}
@Test func overflowOnlyAtFloor() async {
    await propertyCheck(
        count: 50, input: markdownGen, Gen.double(in: 1...120), Gen.double(in: 100...1200),
        Gen.double(in: 50...600)
    ) { md, m, w, h in
        let r = TextFitter.fit(md, maxFontSize: m, in: CGSize(width: w, height: h))
        if r.overflows { #expect(r.fontSize == 14) }
    }
}
