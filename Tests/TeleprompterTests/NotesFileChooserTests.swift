import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Teleprompter

// Open… must offer only notes files (.md, .markdown, .txt), not every kind of plain text.

@MainActor @Suite final class NotesFileChooserTests {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "NotesFileChooserTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func acceptsOnlyNotesExtensionsCaseInsensitively() {
        for name in ["a.md", "b.markdown", "c.txt", "D.MD", "e.Markdown"] {
            #expect(NotesFileChooser.accepts(dir.appending(path: name)), "\(name)")
        }
        for name in ["a.swift", "b.rtf", "c.md.zip", "noextension", "e.text"] {
            #expect(!NotesFileChooser.accepts(dir.appending(path: name)), "\(name)")
        }
    }

    @Test func foldersStayEnabledSoTheUserCanBrowse() throws {
        let folder = dir.appending(path: "Talks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(NotesFileChooser.accepts(URL(fileURLWithPath: folder.path)))
    }

    @Test func contentTypesCoverEachExtension() {
        let types = NotesFileChooser.contentTypes
        #expect(types.count == Set(types).count, "no repeats")
        for ext in ["md", "markdown", "txt"] {
            let type = UTType(filenameExtension: ext)
            #expect(type.map { t in types.contains { t.conforms(to: $0) } } == true, "\(ext)")
        }
    }

    @Test func configuresAnOpenPanelForOneNotesFile() {
        let chooser = NotesFileChooser()
        let panel = NSOpenPanel()
        chooser.configure(panel)
        #expect(
            !panel.allowsMultipleSelection && panel.canChooseFiles && !panel.canChooseDirectories)
        #expect(panel.allowedContentTypes == NotesFileChooser.contentTypes)
        #expect(panel.delegate === chooser)
        #expect(chooser.panel(panel, shouldEnable: dir.appending(path: "x.md")))
        #expect(!chooser.panel(panel, shouldEnable: dir.appending(path: "x.swift")))
    }
}
