import Testing

@testable import Teleprompter

// The panel's frame is saved once a move or resize settles, never for a move the system made
// because the displays changed (so an unplugged display doesn't overwrite the user's frame).

@MainActor private final class SaveCounter {
    var count = 0
}

@MainActor private func settle(_ ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

/// Polls until `condition` holds, failing after ten seconds (other suites can hold the main actor for seconds); the bounded wait, not a fixed
/// sleep, is the pass condition, so a busy machine can't fail the test.
@MainActor private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor @Test func savesOnceAfterMovesSettle() async {
    let saves = SaveCounter()
    let saver = FrameSaver(delay: .milliseconds(40), quietAfterScreenChange: .seconds(1)) {
        saves.count += 1
    }
    saver.frameChanged()
    saver.frameChanged()
    #expect(saver.isPending && saves.count == 0)
    #expect(await waitUntil { saves.count == 1 })
    #expect(!saver.isPending)
    await settle(100)
    #expect(saves.count == 1, "two moves, one save")
}

@MainActor @Test func flushSavesOnlyWhenAMoveIsPending() async {
    let saves = SaveCounter()
    let saver = FrameSaver(delay: .seconds(30), quietAfterScreenChange: .seconds(1)) {
        saves.count += 1
    }
    saver.flush()
    #expect(saves.count == 0, "an untouched frame isn't saved")
    saver.frameChanged()
    saver.flush()
    #expect(saves.count == 1 && !saver.isPending)
    saver.flush()
    #expect(saves.count == 1)
}

@MainActor @Test func movesRightAfterADisplayChangeAreIgnored() async {
    let saves = SaveCounter()
    let saver = FrameSaver(delay: .milliseconds(20), quietAfterScreenChange: .milliseconds(300)) {
        saves.count += 1
    }
    saver.frameChanged()  // The system moves the window first...
    saver.screenParametersChanged()  // ...then reports the display change.
    saver.frameChanged()  // Further system moves during the quiet period.
    #expect(!saver.isPending)
    await settle(100)
    #expect(saves.count == 0)
    await settle(300)
    saver.frameChanged()  // The user moves it afterwards.
    #expect(await waitUntil { saves.count == 1 })
}
