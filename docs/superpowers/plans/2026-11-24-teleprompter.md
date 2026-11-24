# Teleprompter v0.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app showing a notes window under the camera that ScreenFlow does not record.

**Architecture:** Swift package with two targets. `TeleprompterCore` holds all logic that can be tested without a screen (settings, placement, Markdown rendering, shrink-to-fit, file watching, notes storage, mode state) and has a 100% line-coverage gate. `Teleprompter` is a thin AppKit executable (panel, status menu, hotkey) checked by a manual checklist that includes a real ScreenFlow recording.

**Tech Stack:** Swift 6.3, SwiftPM (tools 6.2), AppKit, Carbon hotkeys, `swift-markdown` 0.9.0, Swift Testing, `swift format`.

**Spec:** `docs/superpowers/specs/2026-11-24-teleprompter-design.md`

## Global Constraints

- Minimum macOS 26 (`.macOS(.v26)`); Swift language mode 6 (strict concurrency).
- The notes window has `sharingType = .none` except while the capture check is on. That state is never persisted, and switching modes turns it off.
- Recording mode: `ignoresMouseEvents = true`, the panel can't become key, and the app is never activated.
- Global hotkey ⌃⌥⌘N (Carbon `RegisterEventHotKey`, `kVK_ANSI_N`), no Accessibility permission needed.
- No Dock icon: `LSUIElement = true` in the bundle; `.accessory` activation policy.
- Font size is a *maximum*; shrink-to-fit floor is **14 pt**. Below it, show the "more below" marker.
- License MIT; ad-hoc signed; public repo `reuven/teleprompter`.
- Every test run goes through `~/.local/bin/testslot -- <command>`. Never run tests in parallel outside it.
- `swift format lint --strict -r Sources Tests` clean before every commit; push after committing.
- Shipping code: each task on its own feature branch (`feat/<task-slug>`), merged into `main` and deleted when the task's review passes.
- Doc comments on every non-private type and function explain *why* it exists.
- `TeleprompterCore` must not import Carbon or reference `NSApp`. AppKit is allowed only for `NSFont`, `NSColor`, `NSAttributedString`, `NSParagraphStyle`, and `NSTextList`.
- Property-based tests (the Hypothesis equivalent) use `swift-property-based` (`.package(url: "https://github.com/x-sheep/swift-property-based.git", from: "2.0.1")`, product `PropertyBased`). It's a dependency of the **test targets only**. API: `await propertyCheck(count:input:...) { ... }` with `Gen.*` generators. When a property finds a bug, pin it with a plain `@Test` that hard-codes the shrunk input (this replaces Hypothesis's `@example`), next to the property.
- Mutation testing: Muter on `TeleprompterCore` at the end of Task 7, and again before release (Task 11).

*(Amended 2026-11-24 after Task 1, at Reuven's prompt: property tests, panel invariant tests, earlier mutation testing.)*

## Review Focus

1. **Editors that save by atomic replace** (VS Code, BBEdit, Vim write a temp file and rename it). The watcher must keep firing after the first replace, not go silent. → Task 6.
2. **The open file is deleted, moved, or not valid UTF-8.** Expected: no crash; show an error in the menu and fall back to scratch notes. → Task 7.
3. **The remembered window frame is on an external display that's no longer connected.** Expected: use the default position on a connected display, never an invisible window. → Task 3.
4. **Save-back feedback loop.** The app writes the file, the watcher fires, and the app reloads, which would clobber in-progress typing or move the cursor. Expected: the app's own writes are recognized and ignored. → Task 7.
5. **Edge-case note content:** empty notes, one very long unbroken word, or 200 bullets. Expected: empty → max size, no overflow; huge → 14 pt with `overflows == true`; never a zero or negative font size. → Task 5.

---

## File Structure

```
Package.swift
Sources/TeleprompterCore/
  Mode.swift              Mode state machine + capture-check flag
  Settings.swift          Validated settings value + UserDefaults store
  Placement.swift         Default and restored window frames
  MarkdownRenderer.swift  Markdown → NSAttributedString
  TextFitter.swift        Shrink-to-fit font size search
  FileWatcher.swift       Watches a file path, survives atomic replace
  NotesStore.swift        Scratch notes, open file, save-back, recents
Sources/Teleprompter/
  main.swift              NSApplication bootstrap
  AppDelegate.swift       Wires Core to AppKit
  NotesPanel.swift        NSPanel subclass (sharingType, modes)
  NotesContentView.swift  Edit (NSTextView) vs rendered view
  StatusMenu.swift        Menu-bar item and menu
  HotKey.swift            Carbon global hotkey
Tests/TeleprompterCoreTests/   one file per Core source file
scripts/coverage.sh       100% gate on TeleprompterCore
scripts/build-app.sh      Assembles ad-hoc-signed Teleprompter.app
scripts/Info.plist        Bundle plist template
docs/manual-checklist.md  Pre-release manual checks (incl. ScreenFlow)
```

---

### Task 1: Package skeleton, coverage gate, mode state

**Files:**
- Create: `Package.swift`, `Sources/TeleprompterCore/Mode.swift`, `Sources/Teleprompter/main.swift` (prints nothing; just `NSApplication.shared.run()` placeholder is fine), `Tests/TeleprompterCoreTests/ModeTests.swift`, `scripts/coverage.sh`, `.swift-format` (2-space or 4-space — pick 4, line length 100)

**Interfaces:**
- Produces:
  - `public enum Mode: Sendable, Equatable { case edit, recording }`
  - `public struct ModeState: Sendable, Equatable { public private(set) var mode: Mode; public private(set) var captureVisible: Bool }`
  - `public static func initial(hasNotes: Bool) -> ModeState`. `.recording` if it has notes, `.edit` otherwise; `captureVisible` is false.
  - `public mutating func toggleMode()`. Flips the mode and *always* sets `captureVisible = false`.
  - `public mutating func setCaptureVisible(_ visible: Bool)`
  - `scripts/coverage.sh`: exit 0 only if every file under `Sources/TeleprompterCore/` has 100% line coverage.

- [ ] **Step 1:** Create a branch: `git switch -c feat/skeleton`
- [ ] **Step 2:** Write `Package.swift`: tools 6.2, `platforms: [.macOS(.v26)]`, dependency `.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0")`, library target `TeleprompterCore` (depends on `Markdown`), executable target `Teleprompter` (depends on Core), test target `TeleprompterCoreTests`.
- [ ] **Step 3: Write failing tests** in `ModeTests.swift` (Swift Testing):

```swift
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
    var s = ModeState.initial(hasNotes: true); s.toggleMode()
    #expect(s.mode == .edit); s.toggleMode(); #expect(s.mode == .recording)
}
@Test func toggleTurnsCaptureCheckOff() {
    var s = ModeState.initial(hasNotes: true)
    s.setCaptureVisible(true); #expect(s.captureVisible)
    s.toggleMode(); #expect(s.captureVisible == false)
}
```

- [ ] **Step 4:** Run `~/.local/bin/testslot -- swift test --filter ModeTests`. Expected: compile FAIL (`ModeState` not found).
- [ ] **Step 5:** Implement `Mode.swift` per the Interfaces block.
- [ ] **Step 6:** Run the same command. Expected: 5 tests PASS.
- [ ] **Step 7:** Write `scripts/coverage.sh` (`set -euo pipefail`). Run `swift test --enable-code-coverage` via testslot, get the JSON path from `swift test --show-codecov-path`, then use `jq` to select files whose `filename` contains `/Sources/TeleprompterCore/`. Print each file's `summary.lines.percent`, and exit 1 if any is below 100. Make it executable.
- [ ] **Step 8:** Run `scripts/coverage.sh`. Expected: `Mode.swift 100` and exit 0. Then temporarily comment out one test and confirm it exits 1. Restore the test.
- [ ] **Step 9:** Run `swift format lint --strict -r Sources Tests`. Expected: no output.
- [ ] **Step 10:** Commit ("Add package skeleton, mode state, coverage gate"), push, and merge into main. Delete the branch.

---

### Task 2: Settings

**Files:** Create `Sources/TeleprompterCore/Settings.swift`, `Tests/TeleprompterCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces:
  - `public struct Settings: Codable, Sendable, Equatable`, with fields:
    - `fontSize: Double`, clamped to `14...120`, default `32`
    - `opacity: Double`, snapped to the nearest of `Settings.opacityPresets = [0.5, 0.7, 0.85, 1.0]`, default `0.85`
    - `windowFrame: CGRect?`, default nil
    - `lastFileURL: URL?`, default nil
    - `recentFiles: [URL]`, at most 5, most recent first, no duplicates
  - `public init(...)` with default arguments. The initializer and `init(from:)` both normalize values through the same rules (the Swift equivalent of Pydantic validators), so corrupt stored values never crash the app.
  - `public mutating func noteOpened(_ url: URL)`. Moves `url` to the front of `recentFiles`, trims to 5, and sets `lastFileURL`.
  - `public static let minFontSize: Double = 14`
  - `public final class SettingsStore: @unchecked Sendable { public init(defaults: UserDefaults); public func load() -> Settings; public func save(_ s: Settings) }`. Stores JSON under key `"settings.v1"`. Missing or undecodable data → `Settings()`.

- [ ] **Step 1:** Create a branch: `feat/settings`. In `Package.swift`, add the `swift-property-based` dependency (Global Constraints) to `TeleprompterCoreTests`. Also harden `scripts/coverage.sh`: a missing or non-numeric `percent` must fail the gate (have jq select `(.summary.lines.percent // -1)` and test with `>= 100` numerically). Confirm by running the script once with a deliberately uncovered function and checking `echo $?` prints `1` (not through a pipe). Remove the function.
- [ ] **Step 2: Write failing tests:**

```swift
@Test func defaults() { let s = Settings(); #expect(s.fontSize == 32 && s.opacity == 0.85 && s.recentFiles.isEmpty) }
@Test func clampsFontSize() { #expect(Settings(fontSize: 3).fontSize == 14); #expect(Settings(fontSize: 500).fontSize == 120) }
@Test func snapsOpacity() { #expect(Settings(opacity: 0.8).opacity == 0.85); #expect(Settings(opacity: -1).opacity == 0.5) }
@Test func recentsDedupedCappedOrdered() {
    var s = Settings(); let u = (1...6).map { URL(fileURLWithPath: "/tmp/\($0).md") }
    u.forEach { s.noteOpened($0) }; s.noteOpened(u[2])
    #expect(s.recentFiles.first == u[2] && s.recentFiles.count == 5 && Set(s.recentFiles).count == 5)
    #expect(s.lastFileURL == u[2])
}
@Test func decodingClampsCorruptValues() throws {
    let json = #"{"fontSize":9999,"opacity":7,"recentFiles":[]}"#.data(using: .utf8)!
    let s = try JSONDecoder().decode(Settings.self, from: json)
    #expect(s.fontSize == 120 && s.opacity == 1.0)
}
@Test func storeRoundTrips() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!; let store = SettingsStore(defaults: d)
    var s = Settings(fontSize: 40); s.noteOpened(URL(fileURLWithPath: "/tmp/a.md")); store.save(s)
    #expect(store.load() == s)
}
@Test func storeReturnsDefaultsForGarbage() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!; d.set(Data("nope".utf8), forKey: "settings.v1")
    #expect(SettingsStore(defaults: d).load() == Settings())
}
```

Add these properties, in `SettingsPropertyTests.swift`:

```swift
// any Double — including .nan, ±.infinity, .greatestFiniteMagnitude — normalizes into range
@Test func fontSizeAlwaysInRange() async   // Gen.double(in: -1e9...1e9) plus explicit NaN/inf @Tests
    // #expect((14...120).contains(Settings(fontSize: x).fontSize))
@Test func opacityAlwaysAPreset() async    // #expect(Settings.opacityPresets.contains(Settings(opacity: x).opacity))
@Test func normalizationIsIdempotent() async
    // let s = Settings(fontSize: f, opacity: o); #expect(Settings(fontSize: s.fontSize, opacity: s.opacity) == s)
@Test func codableRoundTrip() async        // encode → decode == original, for generated settings
@Test func recentsInvariant() async        // after any sequence of noteOpened (Gen of 0...20 paths from a pool of 8):
    // count <= 5, no duplicates, first == last opened
@Test func nanFontSizeIsDefault()          // Settings(fontSize: .nan).fontSize == 32  (NaN → default, not min)
@Test func nanOpacityIsDefault()           // Settings(opacity: .nan).opacity == 0.85
```

- [ ] **Step 3:** Run `testslot -- swift test --filter SettingsTests`. Expected: FAIL (not defined).
- [ ] **Step 4:** Implement `Settings.swift`. Watch out: Swift's `min`/`max` pass NaN through, so non-finite values need their own check before clamping. Decoding uses `decodeIfPresent` with the defaults, then the same normalization the initializer uses.
- [ ] **Step 5:** Run the tests. Expected: PASS. Then `scripts/coverage.sh` passes.
- [ ] **Step 6:** Lint, commit ("Add validated settings and store"), push, merge, delete the branch.

---

### Task 3: Window placement

**Files:** Create `Sources/TeleprompterCore/Placement.swift`, `Tests/TeleprompterCoreTests/PlacementTests.swift`

**Interfaces:**
- Produces:
  - `public struct ScreenInfo: Sendable, Equatable { public let frame: CGRect; public let visibleFrame: CGRect; public let isBuiltIn: Bool }`
  - `public enum Placement`
  - `public static let defaultSize = CGSize(width: 640, height: 200)`
  - `public static func cameraScreen(_ screens: [ScreenInfo]) -> ScreenInfo?`. The first built-in screen, else `screens.first`. Callers pass the main screen first.
  - `public static func defaultFrame(on screen: ScreenInfo) -> CGRect`. Horizontally centered on `visibleFrame`, top edge 8 pt below `visibleFrame.maxY` (so below the menu bar and notch).
  - `public static func restoredFrame(saved: CGRect?, screens: [ScreenInfo]) -> CGRect?`. Returns `saved` only if at least 50% of its area intersects some screen's `visibleFrame`; otherwise nil.

- [ ] **Step 1:** Create a branch: `feat/placement`.
- [ ] **Step 2: Write failing tests:**

```swift
let builtIn = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                         visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), isBuiltIn: true)
let external = ScreenInfo(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                          visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), isBuiltIn: false)
@Test func prefersBuiltInScreen() { #expect(Placement.cameraScreen([external, builtIn]) == builtIn) }
@Test func fallsBackToFirstScreen() { #expect(Placement.cameraScreen([external]) == external) }
@Test func noScreens() { #expect(Placement.cameraScreen([]) == nil) }
@Test func defaultIsTopCenter() {
    let f = Placement.defaultFrame(on: builtIn)
    #expect(f.size == Placement.defaultSize && f.midX == 756 && f.maxY == 936)
}
@Test func keepsSavedFrameOnConnectedScreen() {
    let saved = CGRect(x: 100, y: 500, width: 600, height: 200)
    #expect(Placement.restoredFrame(saved: saved, screens: [builtIn]) == saved)
}
@Test func dropsFrameOnDisconnectedDisplay() {   // Review Focus #3
    let saved = CGRect(x: 2000, y: 800, width: 600, height: 200)
    #expect(Placement.restoredFrame(saved: saved, screens: [builtIn]) == nil)
}
@Test func dropsMostlyOffscreenFrame() {
    #expect(Placement.restoredFrame(saved: CGRect(x: 1400, y: 500, width: 600, height: 200), screens: [builtIn]) == nil)
}
@Test func nilSavedIsNil() { #expect(Placement.restoredFrame(saved: nil, screens: [builtIn]) == nil) }
```

Property (Review Focus #3), in the same file:

```swift
@Test func restoredFrameIsMostlyOnScreen() async
    // for random saved rects (origin -5000...5000, size 50...3000) and [builtIn] / [builtIn, external]:
    // if let r = restoredFrame(...) { r == saved, and some screen's visibleFrame ∩ r has area >= 0.5 × r's area }
@Test func defaultFrameInsideVisibleFrame() async
    // for random visibleFrames at least as big as defaultSize: visibleFrame.contains(defaultFrame(on:))
```

- [ ] **Step 3:** Run `testslot -- swift test --filter PlacementTests`. Expected: FAIL.
- [ ] **Step 4:** Implement `Placement.swift`.
- [ ] **Step 5:** Run the tests and then `scripts/coverage.sh`. Expected: both PASS.
- [ ] **Step 6:** Lint, commit ("Add window placement logic"), push, merge, delete the branch.

---

### Task 4: Markdown renderer

**Files:** Create `Sources/TeleprompterCore/MarkdownRenderer.swift`, `Tests/TeleprompterCoreTests/MarkdownRendererTests.swift`

**Interfaces:**
- Produces:
  - `public struct NoteStyle: Sendable { public var fontSize: Double; public var textColor: NSColor }`, with default `textColor = .white`
  - `public enum MarkdownRenderer { public static func render(_ markdown: String, style: NoteStyle) -> NSAttributedString }`

Rendering rules (headings scale with `fontSize`, so shrink-to-fit scales everything together):

| Element | Output |
|---|---|
| Paragraph | system font at `fontSize`; blocks separated by `\n`, paragraphSpacing `0.4 × fontSize` |
| Heading level 1 / 2 / 3+ | bold system font at 1.4× / 1.2× / 1.1× `fontSize` |
| Unordered list item | `"•\t"` prefix; nested level n gets headIndent `n × 1.2 × fontSize` |
| Ordered list item | `"\(index).\t"` prefix, starting from the list's `startIndex` |
| Strong / Emphasis | bold / italic trait added to the current font (they combine) |
| InlineCode | monospaced system font at `fontSize` |
| Link, image, table, HTML, code block | their plain text content only, at `fontSize` |

- [ ] **Step 1:** Create a branch: `feat/markdown`.
- [ ] **Step 2: Write failing tests.** Add a helper `fontAt(_ s: NSAttributedString, _ substring: String) -> NSFont`.

```swift
let style = NoteStyle(fontSize: 20)
@Test func plainParagraph() { let r = MarkdownRenderer.render("Hello", style: style)
    #expect(r.string == "Hello" && fontAt(r, "Hello").pointSize == 20) }
@Test func headingsScale() { let r = MarkdownRenderer.render("# Big\n\n## Mid", style: style)
    #expect(fontAt(r, "Big").pointSize == 28 && fontAt(r, "Mid").pointSize == 24)
    #expect(fontAt(r, "Big").fontDescriptor.symbolicTraits.contains(.bold)) }
@Test func bulletsAndNesting() { let r = MarkdownRenderer.render("- a\n  - b", style: style)
    #expect(r.string.contains("•\ta") && r.string.contains("•\tb"))
    #expect(paragraphStyle(r, "b").headIndent > paragraphStyle(r, "a").headIndent) }
@Test func orderedListStartIndex() { #expect(MarkdownRenderer.render("3. x\n4. y", style: style).string.contains("3.\tx")) }
@Test func strongEmphasisCombine() { let r = MarkdownRenderer.render("***both***", style: style)
    let t = fontAt(r, "both").fontDescriptor.symbolicTraits
    #expect(t.contains(.bold) && t.contains(.italic)) }
@Test func inlineCodeIsMonospaced() { let r = MarkdownRenderer.render("use `ls`", style: style)
    #expect(fontAt(r, "ls").fontDescriptor.symbolicTraits.contains(.monoSpace)) }
@Test func linkShowsTextOnly() { #expect(MarkdownRenderer.render("[site](https://x.y)", style: style).string == "site") }
@Test func emptyInput() { #expect(MarkdownRenderer.render("", style: style).length == 0) }
@Test func usesTextColor() { let r = MarkdownRenderer.render("x", style: NoteStyle(fontSize: 20, textColor: .red))
    #expect(r.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .red) }
```

- [ ] **Step 3:** Run `testslot -- swift test --filter MarkdownRendererTests`. Expected: FAIL.
- [ ] **Step 4:** Implement with a private `struct AttributedStringBuilder: MarkupWalker` that tracks a trait stack (bold/italic) and list depth/index while walking a `Document(parsing:)`. Elements not overridden fall through to `descendInto`, which yields their plain text.
- [ ] **Step 5:** Run the tests and then `scripts/coverage.sh`. Expected: both PASS.
- [ ] **Step 6:** Lint, commit ("Add Markdown renderer"), push, merge, delete the branch.

---

### Task 5: Shrink-to-fit

**Files:** Create `Sources/TeleprompterCore/TextFitter.swift`, `Tests/TeleprompterCoreTests/TextFitterTests.swift`

**Interfaces:**
- Consumes: `MarkdownRenderer.render`, `NoteStyle`, `Settings.minFontSize`
- Produces:
  - `public struct FitResult: Sendable, Equatable { public let fontSize: Double; public let overflows: Bool }`
  - `public enum TextFitter { public static func fit(_ markdown: String, maxFontSize: Double, in size: CGSize) -> FitResult }`
    - Renders at a candidate size and measures with `boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])`.
    - Returns the largest size in whole points, from `minFontSize` to `maxFontSize`, whose height is ≤ `size.height`. Uses a binary search over integers.
    - If nothing fits at `minFontSize`, returns `(minFontSize, overflows: true)`.
    - If `maxFontSize < minFontSize`, treats max as min.

- [ ] **Step 1:** Create a branch: `feat/fit`.
- [ ] **Step 2: Write failing tests:**

```swift
let box = CGSize(width: 600, height: 180)
@Test func shortNoteUsesMax() { #expect(TextFitter.fit("Hi", maxFontSize: 40, in: box) == FitResult(fontSize: 40, overflows: false)) }
@Test func emptyUsesMax() { #expect(TextFitter.fit("", maxFontSize: 40, in: box) == FitResult(fontSize: 40, overflows: false)) }  // Review Focus #5
@Test func longNoteShrinks() {
    let md = (1...8).map { "- point number \($0)" }.joined(separator: "\n")
    let r = TextFitter.fit(md, maxFontSize: 60, in: box)
    #expect(r.fontSize < 60 && r.fontSize >= 14 && !r.overflows)
    // the chosen size really fits and one point larger does not
    #expect(height(md, r.fontSize, box.width) <= box.height)
    #expect(height(md, r.fontSize + 1, box.width) > box.height)
}
@Test func hugeNoteOverflowsAtFloor() {   // Review Focus #5
    let md = (1...200).map { "- bullet \($0)" }.joined(separator: "\n")
    #expect(TextFitter.fit(md, maxFontSize: 40, in: box) == FitResult(fontSize: 14, overflows: true))
}
@Test func longUnbrokenWordNeverBelowFloor() {
    let r = TextFitter.fit(String(repeating: "x", count: 500), maxFontSize: 40, in: box)
    #expect(r.fontSize >= 14)
}
@Test func maxBelowFloorTreatedAsFloor() { #expect(TextFitter.fit("Hi", maxFontSize: 5, in: box).fontSize == 14) }
```

Properties (Review Focus #5), with `count: 50` because each check renders text:

```swift
@Test func fitIsWithinBounds() async
    // random markdown (Gen of 0...30 lines; each "- " + letters/spaces 0...60), maxFontSize 1...120, box 100...1200 × 50...600:
    // 14 <= r.fontSize <= max(14, maxFontSize.rounded(.down))
@Test func fitMeansItFits() async
    // same inputs: if !r.overflows { height(md, r.fontSize, box.width) <= box.height }
@Test func overflowOnlyAtFloor() async
    // same inputs: if r.overflows { r.fontSize == 14 }
```

- [ ] **Step 3:** Run `testslot -- swift test --filter TextFitterTests`. Expected: FAIL.
- [ ] **Step 4:** Implement `TextFitter.swift`.
- [ ] **Step 5:** Run the tests and then `scripts/coverage.sh`. Expected: both PASS.
- [ ] **Step 6:** Lint, commit ("Add shrink-to-fit"), push, merge, delete the branch.

---

### Task 6: File watcher

**Files:** Create `Sources/TeleprompterCore/FileWatcher.swift`, `Tests/TeleprompterCoreTests/FileWatcherTests.swift`

**Interfaces:**
- Produces:
  - `public final class FileWatcher: @unchecked Sendable`
  - `public init(url: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void)`. Starts watching immediately.
  - `public func stop()`. Also called from `deinit`.
- Approach: `DispatchSource.makeFileSystemObjectSource` on an `O_EVTONLY` file descriptor, with events `[.write, .delete, .rename, .extend]`.
  - On `.delete` or `.rename`: cancel the source, then reopen the *path* after a short retry (up to 10 × 50 ms) and call `onChange`. This is what survives atomic replace.
  - If the file never comes back, stop silently. `NotesStore` detects the missing file.

- [ ] **Step 1:** Create a branch: `feat/watcher`.
- [ ] **Step 2: Write failing tests.** Use a temp directory, and `confirmation(expectedCount:)` or an `AsyncStream` with a 2 s timeout.

```swift
@Test func firesOnInPlaceWrite() async throws        // FileHandle append → ≥1 change
@Test func survivesRepeatedAtomicReplace() async throws {   // Review Focus #1
    // write "a" atomically, wait for change; write "b" atomically, wait for change;
    // write "c" atomically → a THIRD change must still arrive
}
@Test func stopsAfterStop() async throws              // stop(), then write → no change within 300 ms
@Test func deletedFileDoesNotCrash() async throws     // delete file, wait 1 s, watcher idle, no crash
```

- [ ] **Step 3:** Run `testslot -- swift test --filter FileWatcherTests`. Expected: FAIL.
- [ ] **Step 4:** Implement `FileWatcher.swift`.
- [ ] **Step 5:** Run the tests 3 times in a row to catch flakiness, then `scripts/coverage.sh`. Expected: all PASS.
- [ ] **Step 6:** Lint, commit ("Add file watcher that survives atomic saves"), push, merge, delete the branch.

---

### Task 7: Notes store

**Files:** Create `Sources/TeleprompterCore/NotesStore.swift`, `Tests/TeleprompterCoreTests/NotesStoreTests.swift`

**Interfaces:**
- Consumes: `FileWatcher`, `Settings`
- Produces:
  - `public enum NotesSource: Equatable, Sendable { case scratch; case file(URL) }`
  - `@MainActor public final class NotesStore`
  - `public init(scratchURL: URL, saveDelay: Duration = .milliseconds(500))`. Loads scratch text from `scratchURL`; empty if missing.
  - `public private(set) var text: String`, `public private(set) var source: NotesSource`, `public private(set) var lastError: String?`
  - `public var onExternalChange: (() -> Void)?`. Called after a reload caused by *another* program.
  - `public func open(_ url: URL)`. On success: `source = .file(url)`, text replaced, watcher started, `lastError = nil`. On failure (missing file, not UTF-8): `source` stays as it was, and `lastError` is set to a one-line message containing the file name.
  - `public func closeFile()`. Returns to `.scratch` with the *saved scratch* text (scratch is never overwritten by file contents).
  - `public func userEdited(_ newText: String)`. Updates `text` and schedules a debounced save to the current source.
  - `public func flush() async`. Performs any pending save now (used on quit and in tests).
  - If the open file disappears and doesn't come back: switch to `.scratch` and set `lastError`.
- Self-write suppression (Review Focus #4): after saving, remember the bytes written. When the watcher fires and the file content equals them, ignore the event.

- [ ] **Step 1:** Create a branch: `feat/notes-store`.
- [ ] **Step 2: Write failing tests** (temp directory; `saveDelay: .milliseconds(10)`):

```swift
@Test func scratchPersists()            // userEdited("a"); flush; new store at same scratchURL → text == "a"
@Test func openLoadsFile()              // file "# Hi" → open → text == "# Hi", source == .file(url)
@Test func editSavesBackToFile()        // open; userEdited("new"); flush → file contents == "new"
@Test func externalChangeReloads()      // open; atomically write "ext" → onExternalChange called, text == "ext"
@Test func ownSaveDoesNotTriggerReload() // open; userEdited("mine"); flush; wait 300 ms → onExternalChange NOT called
@Test func closeFileRestoresScratch()   // scratch "s"; open file "f"; closeFile → text == "s", source == .scratch
@Test func missingFileSetsError()       // open nonexistent → lastError contains file name, source == .scratch
@Test func nonUTF8SetsError()           // file with bytes [0xFF,0xFE,0x00] → lastError set, text unchanged
@Test func deletedOpenFileFallsBack()   // open; delete file; wait → source == .scratch, lastError set
```

Property:

```swift
@Test func scratchRoundTripsAnyUnicode() async
    // any String from Gen.unicodeScalar... including emoji, RTL, combining marks, "\r\n", "":
    // userEdited(s); flush; new store at same scratchURL → text == s
```

- [ ] **Step 3:** Run `testslot -- swift test --filter NotesStoreTests`. Expected: FAIL.
- [ ] **Step 4:** Implement `NotesStore.swift`. Debounce with a cancellable `Task` that sleeps `saveDelay`. Write scratch atomically; write files atomically.
- [ ] **Step 5:** Run the tests 3 times, then `scripts/coverage.sh`. Expected: all PASS.
- [ ] **Step 6:** Lint, commit ("Add notes store with save-back and reload"), push, merge, delete the branch.
- [ ] **Step 7: Mutation testing on `TeleprompterCore`.** On a new branch, `chore/mutation`:
  1. Install Muter (`brew install muter-mutation-testing/formulae/muter`) and run `muter init`. Configure it to run `swift test` through testslot and to mutate only `Sources/TeleprompterCore`.
  2. Run it.
  3. For every surviving mutant that reflects real logic (not doc strings or log text), write a test that kills it, then commit.
  4. Record the mutation score in `docs/mutation-testing.md`.
  5. If Muter can't build or run with Swift 6.3, write down exactly what failed in that file instead, commit, and move on. Never claim a score you didn't get.

---

### Task 8: App shell + real-window ScreenFlow checkpoint

**Files:**
- Create: `Sources/Teleprompter/AppDelegate.swift`, `NotesPanel.swift`, `StatusMenu.swift`, `scripts/Info.plist`, `scripts/build-app.sh`, `Tests/TeleprompterTests/NotesPanelTests.swift`
- Modify: `Sources/Teleprompter/main.swift`, `Package.swift` (new test target `TeleprompterTests` depending on the executable target, using `@testable import Teleprompter`), `scripts/coverage.sh` (also gate `Sources/Teleprompter/NotesPanel.swift` at 100%)

**Interfaces:**
- Consumes: `Settings`, `SettingsStore`, `Placement`, `ModeState`
- Produces:
  - `final class NotesPanel: NSPanel`, created with:
    - style `[.borderless, .nonactivatingPanel, .resizable]`
    - level `.floating`
    - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
    - `isMovableByWindowBackground = true`, `hidesOnDeactivate = false`, `sharingType = .none`
    - rounded dark background (alpha from `settings.opacity`)
  - `var mode: Mode`. `didSet` sets `ignoresMouseEvents = (mode == .recording)`, and `canBecomeKey` returns `mode == .edit`.
  - `func setCaptureVisible(_ on: Bool)`. Sets `sharingType` to `.readOnly` or `.none`, and toggles a 4 pt red border plus a "VISIBLE TO RECORDING" label.
  - `StatusMenu` items (wired in Task 10): Edit Notes / Lock for Recording (toggle), Open…, Open Recent ▸, Close File, Larger Text, Smaller Text, Opacity ▸, Show in Recordings (Test), Quit.
  - `scripts/build-app.sh`:
    1. `swift build -c release`
    2. Assemble `build/Teleprompter.app` with `Contents/MacOS/Teleprompter` and `Contents/Info.plist` (`LSUIElement` true, `CFBundleIdentifier` `co.lerner.teleprompter`, `LSMinimumSystemVersion` 26.0, version from `git describe --tags --always`).
    3. `codesign --force --sign - build/Teleprompter.app`

- [ ] **Step 1:** Create a branch: `feat/app-shell`.
- [ ] **Step 2: Write failing panel tests** (these pin the anti-goals; no screen needed):

```swift
@MainActor @Test func newPanelIsHiddenFromCapture() { #expect(NotesPanel(settings: Settings()).sharingType == .none) }
@MainActor @Test func recordingModeIgnoresClicksAndFocus() {
    let p = NotesPanel(settings: Settings()); p.mode = .recording
    #expect(p.ignoresMouseEvents && !p.canBecomeKey && !p.canBecomeMain) }
@MainActor @Test func editModeAcceptsClicksAndFocus() {
    let p = NotesPanel(settings: Settings()); p.mode = .edit
    #expect(!p.ignoresMouseEvents && p.canBecomeKey) }
@MainActor @Test func captureCheckTogglesSharing() {
    let p = NotesPanel(settings: Settings())
    p.setCaptureVisible(true); #expect(p.sharingType == .readOnly)
    p.setCaptureVisible(false); #expect(p.sharingType == .none) }
@MainActor @Test func panelIsNonActivatingAndOnAllSpaces() {
    let p = NotesPanel(settings: Settings())
    #expect(p.styleMask.contains(.nonactivatingPanel))
    #expect(p.collectionBehavior.contains(.canJoinAllSpaces) && p.collectionBehavior.contains(.fullScreenAuxiliary)) }
@MainActor @Test func opacityFromSettings() { #expect(NotesPanel(settings: Settings(opacity: 0.5)).backgroundAlpha == 0.5) }
```

Run `testslot -- swift test --filter NotesPanelTests`. Expected: FAIL (`NotesPanel` not defined).
- [ ] **Step 2b:** Implement `NotesPanel(settings:)` (with `var backgroundAlpha: Double` exposed for the test). Then implement the status item with Quit and the capture-check toggle, and placement on launch (`Placement.restoredFrame` ?? `defaultFrame(on: cameraScreen)`). Show fixed sample text. Save the frame to settings on move and resize.
- [ ] **Step 3:** Run `scripts/build-app.sh && open build/Teleprompter.app`. Expected: no Dock icon, a menu-bar icon, and the panel at top center.
- [ ] **Step 4: CHECKPOINT with Reuven.** He records with ScreenFlow while:
  - the panel is hidden
  - he toggles Show in Recordings
  - a full-screen app is in front

  Expected: the panel is absent from the recording except during the test toggle, where it has the red border. **Stop the plan if hiding fails**, and go back to the spec's fallback discussion.
- [ ] **Step 5:** Run `scripts/coverage.sh`. Expected: Core and `NotesPanel.swift` at 100%. Then and lint. Commit ("Add app shell, panel, build script"), push, merge, delete the branch.

---

### Task 9: Edit and recording views, global hotkey

**Files:**
- Create: `Sources/Teleprompter/NotesContentView.swift`, `Sources/Teleprompter/HotKey.swift`
- Modify: `AppDelegate.swift`, `NotesPanel.swift`

**Interfaces:**
- Consumes: `NotesStore`, `MarkdownRenderer`, `TextFitter`, `ModeState`, `Settings`
- Produces:
  - `final class NotesContentView: NSView`
    - In edit mode: an `NSTextView` showing raw text. On each change it calls `store.userEdited`.
    - In recording mode: a non-editable view showing `MarkdownRenderer.render(text, style: NoteStyle(fontSize: fit.fontSize))`, where `fit = TextFitter.fit(text, maxFontSize: settings.fontSize, in: contentBounds)`. It re-fits when the bounds or text change. If `fit.overflows`, it shows a "▼ more below" badge pinned to the bottom edge.
  - `final class HotKey { init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) }`. Returns nil if registration fails; the menu then shows "Shortcut unavailable".
  - The toggle (hotkey or menu): `modeState.toggleMode()`, then the panel's mode, then `panel.setCaptureVisible(false)`, then the content view's mode. Entering edit makes the panel key. Leaving edit calls `makeFirstResponder(nil)`, resigns key, and does `previousApp?.activate()` if the app ever became active.

- [ ] **Step 1:** Create a branch: `feat/views-hotkey`.
- [ ] **Step 2:** Implement per the Interfaces block. The launch mode is `ModeState.initial(hasNotes: !store.text.isEmpty)`.
- [ ] **Step 3:** Build and run. Manually check:
  1. Type Markdown in edit mode.
  2. Press ⌃⌥⌘N from Safari. Expected: the rendered view appears, and Safari keeps focus and keeps receiving typing.
  3. Click through the panel onto Safari content. Expected: Safari gets the click.
  4. Shrink the window. Expected: the text shrinks; at the floor, the badge appears.
  5. Press ⌃⌥⌘N again. Expected: you can type in the panel.
- [ ] **Step 4:** Run coverage and lint. Commit ("Add edit/recording views and global hotkey"), push, merge, delete the branch.

---

### Task 10: File menu, appearance, persistence wiring

**Files:** Modify `AppDelegate.swift`, `StatusMenu.swift`, `NotesPanel.swift`

**Interfaces:**
- Consumes: `NotesStore.open/closeFile/lastError/onExternalChange`, `Settings.noteOpened/recentFiles/opacityPresets`, `SettingsStore`
- Behavior:
  - **Open…** uses `NSOpenPanel`, restricted to `.md`, `.markdown`, `.txt`.
  - **Open Recent** lists `settings.recentFiles`.
  - On launch, reopen `settings.lastFileURL` if it exists; otherwise use scratch.
  - `store.lastError` appears as a disabled menu item at the top of the menu until the next successful open.
  - **Larger / Smaller Text** steps `settings.fontSize` by ±2, and ⌘+ / ⌘− do the same while the panel is key.
  - **Opacity** submenu shows the presets with a checkmark.
  - Settings are saved on every change.
  - On quit, `await store.flush()` before terminating (`applicationShouldTerminate` → `.terminateLater`).

- [ ] **Step 1:** Create a branch: `feat/menus`.
- [ ] **Step 2:** Implement the behavior above.
- [ ] **Step 3:** Build and run. Manually check:
  1. Open a `.md` file, edit it in BBEdit or VS Code, and save. Expected: the panel updates.
  2. Edit in the panel. Expected: the file changes on disk.
  3. Delete the file. Expected: the error appears in the menu and the app falls back to scratch.
  4. Quit and relaunch. Expected: the same file, size, opacity, and position come back.
  5. Unplug the external display, if available. Expected: the panel comes back at the default position.
- [ ] **Step 4:** Run coverage and lint. Commit ("Wire file menu, appearance, persistence"), push, merge, delete the branch.

---

### Task 11: Release v0.1.0

**Files:** Create `docs/manual-checklist.md`; modify `README.md`

- [ ] **Step 1:** Create a branch: `release/0.1.0`.
- [ ] **Step 2:** Write `docs/manual-checklist.md`, consolidating the manual checks from Tasks 8–10 into one list, with the ScreenFlow recording check first.
- [ ] **Step 3:** Update `README.md` with:
  - installing from a release zip (approving it in System Settings › Privacy & Security, since it isn't notarized)
  - building from source (`scripts/build-app.sh`)
  - usage and the ⌃⌥⌘N shortcut
  - the "re-check after macOS/ScreenFlow updates" note
- [ ] **Step 4:** Mutation testing. Try installing Muter (`brew install muter-mutation-testing/formulae/muter`) and run it on `TeleprompterCore`. If it works, close real logic gaps with tests. If it doesn't support Swift 6.3, note that in `README.md` under Development and move on.
- [ ] **Step 5:** Run the full gate: `scripts/coverage.sh`. Expected: exit 0. Check the exit status directly; don't chain it with `&&`.
- [ ] **Step 6:** Run every item in `docs/manual-checklist.md` with Reuven.
- [ ] **Step 7:** Merge into main. Tag `v0.1.0` and push the tag. Then `rm -rf dist && mkdir dist`, run `scripts/build-app.sh`, `ditto -c -k --keepParent build/Teleprompter.app dist/Teleprompter-0.1.0.zip`, and `gh release create v0.1.0 dist/Teleprompter-0.1.0.zip --notes-file <(release notes)`. Delete the release branch.
