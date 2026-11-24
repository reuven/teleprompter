import Carbon.HIToolbox
import Testing

@testable import Teleprompter

// F19 with all four modifiers: a combination nothing else on the Mac uses, so these tests never
// collide with the running app's ⌃⌥⌘N. Hotkey presses are simulated by sending the same Carbon
// event the system sends, which runs the real dispatch path.

private let testKey = UInt32(kVK_F19)
private let testModifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)

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

@MainActor @Test func hotKeyRunsItsHandlerWhenPressed() throws {
    var presses = 0
    let key = try #require(HotKey(keyCode: testKey, modifiers: testModifiers) { presses += 1 })
    #expect(press(key.id) == noErr)
    #expect(presses == 1)
}

@MainActor @Test func secondRegistrationOfTheSameKeyFails() throws {
    let first = try #require(HotKey(keyCode: testKey, modifiers: testModifiers) {})
    #expect(HotKey(keyCode: testKey, modifiers: testModifiers) {} == nil)
    withExtendedLifetime(first) {}
}

@MainActor @Test func releasingAHotKeyFreesTheCombination() throws {
    var key = HotKey(keyCode: testKey, modifiers: testModifiers) {}
    #expect(key != nil)
    key = nil
    #expect(HotKey(keyCode: testKey, modifiers: testModifiers) {} != nil)
}

@MainActor @Test func eachHotKeyOnlyAnswersItsOwnPresses() throws {
    var a = 0
    var b = 0
    let keyA = try #require(HotKey(keyCode: testKey, modifiers: testModifiers) { a += 1 })
    let keyB = try #require(
        HotKey(keyCode: UInt32(kVK_F18), modifiers: testModifiers) { b += 1 })
    #expect(press(keyB.id) == noErr)
    #expect(press(keyA.id) == noErr)
    #expect(press(keyA.id) == noErr)
    #expect(a == 2 && b == 1)
}

@MainActor @Test func eventsWithoutAnIdAreNotHandled() throws {
    var presses = 0
    let key = try #require(HotKey(keyCode: testKey, modifiers: testModifiers) { presses += 1 })
    #expect(press(nil) == OSStatus(eventNotHandledErr))
    #expect(presses == 0)
    withExtendedLifetime(key) {}
}
