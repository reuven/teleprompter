import Foundation
import Testing

@testable import TeleprompterCore

@Test func defaults() {
    let s = Settings()
    #expect(s.fontSize == 32 && s.opacity == 0.85 && s.recentFiles.isEmpty)
}

@Test func clampsFontSize() {
    #expect(Settings(fontSize: 3).fontSize == 14)
    #expect(Settings(fontSize: 500).fontSize == 120)
}

@Test func snapsOpacity() {
    #expect(Settings(opacity: 0.8).opacity == 0.85)
    #expect(Settings(opacity: -1).opacity == 0.5)
}

@Test func recentsDedupedCappedOrdered() {
    var s = Settings()
    let u = (1...6).map { URL(fileURLWithPath: "/notes/\($0).md") }
    for url in u { s.noteOpened(url) }
    s.noteOpened(u[2])
    #expect(
        s.recentFiles.first == u[2] && s.recentFiles.count == 5 && Set(s.recentFiles).count == 5)
    #expect(s.lastFileURL == u[2])
}

@Test func decodingClampsCorruptValues() throws {
    let json = #"{"fontSize":9999,"opacity":7,"recentFiles":[]}"#.data(using: .utf8)!
    let s = try JSONDecoder().decode(Settings.self, from: json)
    #expect(s.fontSize == 120 && s.opacity == 1.0)
}

@Test func decodingTrimsAndDedupesRecents() throws {
    let urls = (1...8).map { "\"file:///notes/\($0).md\"" } + ["\"file:///notes/1.md\""]
    let json = Data("{\"recentFiles\":[\(urls.joined(separator: ","))]}".utf8)
    let s = try JSONDecoder().decode(Settings.self, from: json)
    #expect(s.recentFiles.count == 5 && Set(s.recentFiles).count == 5)
    #expect(s.recentFiles.first == URL(string: "file:///notes/1.md"))
}

@Test func storeRoundTrips() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    let store = SettingsStore(defaults: d)
    var s = Settings(fontSize: 40)
    s.noteOpened(URL(fileURLWithPath: "/notes/a.md"))
    store.save(s)
    #expect(store.load() == s)
}

@Test func storeReturnsDefaultsForGarbage() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    d.set(Data("nope".utf8), forKey: "settings.v1")
    #expect(SettingsStore(defaults: d).load() == Settings())
}

@Test func storeReturnsDefaultsWhenEmpty() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    #expect(SettingsStore(defaults: d).load() == Settings())
}

@Test func decodingEmptyObjectGivesDefaults() throws {
    let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(s == Settings())
}

@Test func opacityInfinityAndHugeSnapToNearestEnd() {
    #expect(Settings(opacity: .infinity).opacity == 1.0)
    #expect(Settings(opacity: 1e300).opacity == 1.0)
    #expect(Settings(opacity: -.infinity).opacity == 0.5)
}

@Test func wrongTypedKeyDegradesAlone() throws {
    let json = Data(
        #"{"fontSize":"big","opacity":0.5,"recentFiles":["file:///notes/a.md","file:///notes/b.md"]}"#
            .utf8)
    let s = try JSONDecoder().decode(Settings.self, from: json)
    #expect(s.fontSize == 32 && s.opacity == 0.5)
    #expect(
        s.recentFiles == [URL(string: "file:///notes/a.md")!, URL(string: "file:///notes/b.md")!])
}

@Test func invalidRecentsArrayBecomesEmpty() throws {
    let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"recentFiles":"nope"}"#.utf8))
    #expect(s.recentFiles.isEmpty)
}

@Test func mutationStaysNormalized() {
    var s = Settings()
    s.fontSize = 500
    #expect(s.fontSize == 120)
    s.opacity = .nan
    #expect(s.opacity == 0.85)
    s.opacity = 0.6
    #expect(s.opacity == 0.5)
}

@Test func stepsFontSizeByTwoPointsAndStopsAtTheLimits() {
    var s = Settings(fontSize: 32)
    s.stepFontSize(1)
    #expect(s.fontSize == 34)
    s.stepFontSize(-1)
    s.stepFontSize(-1)
    #expect(s.fontSize == 30)
    s = Settings(fontSize: 119)
    s.stepFontSize(1)
    #expect(s.fontSize == 120 && !s.canMakeTextLarger && s.canMakeTextSmaller)
    s = Settings(fontSize: 15)
    s.stepFontSize(-1)
    #expect(s.fontSize == 14 && !s.canMakeTextSmaller && s.canMakeTextLarger)
}

@Test func launchFileIsTheLastFileOnlyWhileItExists() {
    let url = URL(fileURLWithPath: "/notes/talk.md")
    #expect(Settings().launchFile(exists: { _ in true }) == nil)
    #expect(Settings(lastFileURL: url).launchFile(exists: { $0 == url }) == url)
    #expect(Settings(lastFileURL: url).launchFile(exists: { _ in false }) == nil)
}

@Test func recentsTreatTwoPathsToOneFileAsOne() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "SettingsTests-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "talk.md")
    try Data("x".utf8).write(to: file)
    let link = dir.appending(path: "link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    var s = Settings()
    s.noteOpened(file)
    s.noteOpened(link)
    s.noteOpened(dir.appending(path: "sub/../talk.md"))
    #expect(s.recentFiles.count == 1)
    #expect(s.lastFileURL == s.recentFiles.first)
    #expect(Settings(recentFiles: [file, link]).recentFiles.count == 1, "decoded lists too")
}
