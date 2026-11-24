import Carbon.HIToolbox

/// A system-wide keyboard shortcut that runs `handler` whichever app is in front.
///
/// Why Carbon: `RegisterEventHotKey` is still the only public macOS API for a global shortcut
/// that needs no Accessibility or Input Monitoring permission, and it consumes the keystroke, so
/// pressing it while recording in another app never types into that app. NSEvent's global
/// monitors can only observe, and need permission.
///
/// The registration lives exactly as long as the object: releasing it unregisters the shortcut.
/// The failable initializer returns nil when the system refuses the combination (usually because
/// another app owns it), so the caller can tell the user instead of failing silently.
@MainActor
final class HotKey {
    /// The four-character signature that marks this app's hotkey IDs ("TLPR").
    static let signature: OSType = 0x544C_5052
    // Each instance gets its own id so the shared event handler path can tell them apart.
    private static var nextID: UInt32 = 1

    /// The id carried by this shortcut's press events; exposed so tests can simulate a press.
    let id: EventHotKeyID
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers `keyCode` with Carbon `modifiers` (e.g. `controlKey | optionKey | cmdKey`) and
    /// calls `handler` on each press. Returns nil if the shortcut can't be registered.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        Self.nextID += 1
        self.handler = handler

        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            InstallEventHandler(target, hotKeyCallback, 1, &pressed, context, &handlerRef)
                == noErr,
            RegisterEventHotKey(keyCode, modifiers, id, target, 0, &hotKeyRef) == noErr
        else {
            // deinit runs for a failed init too and removes whatever was installed.
            return nil
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Runs the handler if `pressed` is this shortcut's id. Every `HotKey` sees every press sent
    /// to the app, so presses carrying another id (or none) are passed on unhandled.
    fileprivate func handle(_ pressed: EventHotKeyID?) -> OSStatus {
        guard let pressed, pressed.signature == id.signature, pressed.id == id.id else {
            return OSStatus(eventNotHandledErr)
        }
        handler()
        return noErr
    }
}

/// The C callback Carbon calls for hotkey presses; forwards the press's id to the `HotKey` that
/// installed it. Carbon delivers application-target events on the main thread. The id is read
/// here, before hopping onto the main actor, because the event reference itself isn't Sendable.
private func hotKeyCallback(
    _: EventHandlerCallRef?, event: EventRef?, context: UnsafeMutableRawPointer?
) -> OSStatus {
    var pressed = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &pressed)
    let id = status == noErr ? pressed : nil
    let hotKey = Unmanaged<HotKey>.fromOpaque(context!).takeUnretainedValue()
    return MainActor.assumeIsolated { hotKey.handle(id) }
}
