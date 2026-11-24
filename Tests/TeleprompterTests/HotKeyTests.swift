import Carbon.HIToolbox
import Testing

@testable import Teleprompter

// Hotkey presses are simulated by sending the same Carbon event the system sends, which runs the
// real dispatch path. The registrations are real and global, so each test process uses its own
// combination, derived from its PID: one of F13–F20 (keys most Mac keyboards lack, with no system
// shortcut) with one of four three- or four-modifier sets, and the next F-key for the
// second-key test. None of them is the app's ⌃⌥⌘N.
//
// Why per process: two `swift test` runs at once would otherwise register the very same
// combination. On macOS 26.5 that was measured not to fail (RegisterEventHotKey refuses a
// duplicate only within one process), but a different key per process keeps the runs apart if a
// later macOS starts refusing it. If registration ever does fail, the tests say so rather than
// reporting a broken HotKey.

private let functionKeys = [
    kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
].map(UInt32.init)
private let modifierSets = [
    controlKey | optionKey | cmdKey | shiftKey, controlKey | optionKey | shiftKey,
    controlKey | cmdKey | shiftKey, optionKey | cmdKey | shiftKey,
].map(UInt32.init)

/// This process's combination: two different keys with the same modifiers.
private let testCombo: (key: UInt32, other: UInt32, modifiers: UInt32) = {
    let index = Int(getpid()) % (functionKeys.count * modifierSets.count)
    return (
        functionKeys[index % functionKeys.count],
        functionKeys[(index + 1) % functionKeys.count],
        modifierSets[index / functionKeys.count]
    )
}()

/// Registers this process's test key (or `other`), failing the test with a clear message if the
/// system refuses it, so a taken combination isn't mistaken for a broken `HotKey`.
@MainActor private func register(
    other: Bool = false, _ handler: @escaping () -> Void = {}
) throws -> HotKey {
    let keyCode = other ? testCombo.other : testCombo.key
    return try #require(
        HotKey(keyCode: keyCode, modifiers: testCombo.modifiers, handler: handler),
        "test hotkey \(keyCode)/\(testCombo.modifiers) refused: is another process holding it?")
}

/// Sends a hot-key-pressed event carrying `id` (or no id at all) to the application target.
@MainActor private func press(_ id: EventHotKeyID?) -> OSStatus {
    var event: EventRef?
    CreateEvent(
        nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
        EventAttributes(kEventAttributeNone), &event)
    defer { ReleaseEvent(event) }
    if var id {
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &id)
    }
    return SendEventToEventTarget(event, GetApplicationEventTarget())
}

@MainActor @Test(.tags(.guiSession)) func hotKeyRunsItsHandlerWhenPressed() throws {
    var presses = 0
    let key = try register { presses += 1 }
    #expect(press(key.id) == noErr)
    #expect(presses == 1)
}

@MainActor @Test(.tags(.guiSession)) func secondRegistrationOfTheSameKeyFails() throws {
    let first = try register()
    #expect(HotKey(keyCode: testCombo.key, modifiers: testCombo.modifiers) {} == nil)
    withExtendedLifetime(first) {}
}

@MainActor @Test(.tags(.guiSession)) func releasingAHotKeyFreesTheCombination() throws {
    var key: HotKey? = try register()
    #expect(key != nil)
    key = nil
    #expect(HotKey(keyCode: testCombo.key, modifiers: testCombo.modifiers) {} != nil)
}

@MainActor @Test(.tags(.guiSession)) func eachHotKeyOnlyAnswersItsOwnPresses() throws {
    var a = 0
    var b = 0
    let keyA = try register { a += 1 }
    let keyB = try register(other: true) { b += 1 }
    #expect(press(keyB.id) == noErr)
    #expect(press(keyA.id) == noErr)
    #expect(press(keyA.id) == noErr)
    #expect(a == 2 && b == 1)
}

@MainActor @Test(.tags(.guiSession)) func eventsWithoutAnIdAreNotHandled() throws {
    var presses = 0
    let key = try register { presses += 1 }
    #expect(press(nil) == OSStatus(eventNotHandledErr))
    #expect(presses == 0)
    withExtendedLifetime(key) {}
}
