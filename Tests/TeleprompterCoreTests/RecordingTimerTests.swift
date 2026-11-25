import Foundation
import PropertyBased
import Testing

@testable import TeleprompterCore

// The recording timer's rules: one key cycles start → stop → restart, elapsed time comes from
// the instants it's given (a monotonic clock in the app), and the display text and color level
// follow whole seconds, so the color changes exactly when the shown number does.

@Test func pressCyclesStartStopRestart() {
    let t0 = ContinuousClock.now
    var timer = RecordingTimer()
    #expect(timer.phase == .hidden && !timer.isVisible && !timer.isRunning)
    timer.press(at: t0)
    #expect(timer.phase == .running(since: t0) && timer.isRunning && timer.isVisible)
    timer.press(at: t0 + .seconds(47))
    #expect(timer.phase == .stopped(elapsed: .seconds(47)) && !timer.isRunning && timer.isVisible)
    #expect(timer.elapsed(at: t0 + .seconds(500)) == .seconds(47), "a stopped timer is frozen")
    timer.press(at: t0 + .seconds(600))
    #expect(timer.phase == .running(since: t0 + .seconds(600)))
    #expect(timer.elapsed(at: t0 + .seconds(601)) == .seconds(1), "a restart counts from zero")
}

@Test func hideResets() {
    let t0 = ContinuousClock.now
    var timer = RecordingTimer()
    timer.press(at: t0)
    timer.hide()
    #expect(timer.phase == .hidden && !timer.isVisible)
    #expect(timer.elapsed(at: t0 + .seconds(10)) == .zero)
    timer.press(at: t0 + .seconds(20))
    #expect(timer.elapsed(at: t0 + .seconds(21)) == .seconds(1))
}

@Test func elapsedNeverNegative() {
    let t0 = ContinuousClock.now
    var timer = RecordingTimer()
    timer.press(at: t0)
    #expect(timer.elapsed(at: t0 - .seconds(3)) == .zero)
    timer.press(at: t0 - .seconds(3))
    #expect(timer.phase == .stopped(elapsed: .zero))
}

@Test func formats() {
    #expect(TimerDisplay.format(seconds: 0) == "0:00")
    #expect(TimerDisplay.format(seconds: 42) == "0:42")
    #expect(TimerDisplay.format(seconds: 600) == "10:00")
    #expect(TimerDisplay.format(seconds: 3599) == "59:59")
    #expect(TimerDisplay.format(seconds: 3723) == "1:02:03")
    #expect(TimerDisplay.text(elapsed: .milliseconds(42_900), target: nil) == "0:42")
    #expect(TimerDisplay.text(elapsed: .seconds(42), target: 60) == "0:42 / 1:00")
}

@Test func levelsAtTheBoundaries() {
    #expect(TimerDisplay.level(elapsed: .seconds(54), target: 60) == .normal)
    #expect(TimerDisplay.level(elapsed: .milliseconds(54_999), target: 60) == .normal)
    #expect(TimerDisplay.level(elapsed: .seconds(55), target: 60) == .warning)
    #expect(TimerDisplay.level(elapsed: .milliseconds(59_999), target: 60) == .warning)
    #expect(TimerDisplay.level(elapsed: .seconds(60), target: 60) == .over)
    #expect(TimerDisplay.level(elapsed: .seconds(9_999), target: nil) == .normal)
}

@Test func stripTakesTheBottom() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
    #expect(TimerStrip.notesFrame(in: bounds, showsTimer: false) == bounds)
    #expect(
        TimerStrip.notesFrame(in: bounds, showsTimer: true)
            == CGRect(x: 0, y: 30, width: 400, height: 170))
    let tiny = CGRect(x: 0, y: 0, width: 400, height: 10)
    #expect(TimerStrip.notesFrame(in: tiny, showsTimer: true).size.height == 0)
}

/// Reads "h:mm:ss" or "m:ss" back into seconds; nil if a field after the first isn't two digits.
private func parse(_ text: String) -> Int? {
    let fields = text.split(separator: ":").map(String.init)
    guard (2...3).contains(fields.count), fields.dropFirst().allSatisfy({ $0.count == 2 }) else {
        return nil
    }
    return fields.reduce(0) { total, field in total * 60 + (Int(field) ?? -1_000_000) }
}

@Test func formatRoundTrips() async {
    await propertyCheck(input: Gen.int(in: 0...360_000)) { seconds in
        #expect(parse(TimerDisplay.format(seconds: seconds)) == seconds)
    }
}

private func rank(_ level: TimerLevel) -> Int {
    switch level {
    case .normal: 0
    case .warning: 1
    case .over: 2
    }
}

@Test func levelNeverGoesBackAsTimePasses() async {
    await propertyCheck(
        input: Gen.int(in: 0..<Settings.timerTargetPresets.count), Gen.int(in: 0...400_000),
        Gen.int(in: 0...400_000)
    ) { preset, a, b in
        let target = Settings.timerTargetPresets[preset]
        let (early, late) = (min(a, b), max(a, b))
        #expect(
            rank(TimerDisplay.level(elapsed: .milliseconds(early), target: target))
                <= rank(TimerDisplay.level(elapsed: .milliseconds(late), target: target)))
    }
}
