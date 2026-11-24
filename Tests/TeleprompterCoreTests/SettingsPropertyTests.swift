import Foundation
import PropertyBased
import Testing

@testable import TeleprompterCore

private let pool = (0..<8).map { URL(fileURLWithPath: "/notes/pool-\($0).md") }

@Test func fontSizeAlwaysInRange() async {
    await propertyCheck(input: Gen.double(in: -1e9...1e9)) { x in
        #expect((14.0...120.0).contains(Settings(fontSize: x).fontSize))
    }
}

@Test func fontSizeExtremesInRange() {
    for x in [Double.infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
        #expect((14.0...120.0).contains(Settings(fontSize: x).fontSize))
    }
}

@Test func opacityAlwaysAPreset() async {
    await propertyCheck(input: Gen.double(in: -1e9...1e9)) { x in
        #expect(Settings.opacityPresets.contains(Settings(opacity: x).opacity))
    }
}

@Test func opacityExtremesArePresets() {
    for x in [Double.infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
        #expect(Settings.opacityPresets.contains(Settings(opacity: x).opacity))
    }
}

@Test func normalizationIsIdempotent() async {
    await propertyCheck(input: Gen.double(in: -1e4...1e4), Gen.double(in: -10...10)) { f, o in
        let s = Settings(fontSize: f, opacity: o)
        #expect(Settings(fontSize: s.fontSize, opacity: s.opacity) == s)
    }
}

@Test func codableRoundTrip() async {
    await propertyCheck(
        input: Gen.double(in: -1e4...1e4), Gen.double(in: -10...10),
        Gen.int(in: 0...7).array(of: 0...20)
    ) { f, o, opened in
        var s = Settings(fontSize: f, opacity: o)
        for i in opened { s.noteOpened(pool[i]) }
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Test func recentsInvariant() async {
    await propertyCheck(input: Gen.int(in: 0...7).array(of: 1...20)) { opened in
        var s = Settings()
        for i in opened { s.noteOpened(pool[i]) }
        #expect(s.recentFiles.count <= 5)
        #expect(Set(s.recentFiles).count == s.recentFiles.count)
        #expect(s.recentFiles.first == opened.last.map { pool[$0] })
        #expect(s.lastFileURL == opened.last.map { pool[$0] })
    }
}

@Test func nanFontSizeIsDefault() { #expect(Settings(fontSize: .nan).fontSize == 32) }
@Test func nanOpacityIsDefault() { #expect(Settings(opacity: .nan).opacity == 0.85) }
