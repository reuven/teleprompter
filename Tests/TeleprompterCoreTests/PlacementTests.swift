import CoreGraphics
import Foundation
import PropertyBased
import Testing

@testable import TeleprompterCore

private let builtIn = ScreenInfo(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), isBuiltIn: true)
private let external = ScreenInfo(
    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), isBuiltIn: false)

@Test func prefersBuiltInScreen() {
    #expect(Placement.cameraScreen([external, builtIn]) == builtIn)
}
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

@Test func dropsFrameOnDisconnectedDisplay() {
    let saved = CGRect(x: 2000, y: 800, width: 600, height: 200)
    #expect(Placement.restoredFrame(saved: saved, screens: [builtIn]) == nil)
}

@Test func dropsMostlyOffscreenFrame() {
    let saved = CGRect(x: 1400, y: 500, width: 600, height: 200)
    #expect(Placement.restoredFrame(saved: saved, screens: [builtIn]) == nil)
}

@Test func nilSavedIsNil() {
    #expect(Placement.restoredFrame(saved: nil, screens: [builtIn]) == nil)
}

@Test func noScreensIsNil() {
    let saved = CGRect(x: 100, y: 500, width: 600, height: 200)
    #expect(Placement.restoredFrame(saved: saved, screens: []) == nil)
}

@Test func exactlyHalfOnScreenIsKept() {
    // 300 of 600 pt width is on the built-in screen: exactly 50%.
    let saved = CGRect(x: 1212, y: 500, width: 600, height: 200)
    #expect(Placement.restoredFrame(saved: saved, screens: [builtIn]) == saved)
}

@Test func halfOnEachScreenIsNotSummed() {
    // Straddles two adjacent screens: 50% on each, so each single screen qualifies.
    let saved = CGRect(x: 1412, y: 500, width: 200, height: 200)  // 100 pt on each side
    #expect(Placement.restoredFrame(saved: saved, screens: [builtIn, external]) == saved)
    let gap = ScreenInfo(
        frame: CGRect(x: 1600, y: 0, width: 1000, height: 1000),
        visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 1000), isBuiltIn: false)
    // 50 left (25%), 50 gap, 100 right (50%) would pass; use a layout where each side is < 50%.
    let straddle = CGRect(x: 1462, y: 500, width: 200, height: 200)  // 50 left, 88 gap, 62 right
    #expect(Placement.restoredFrame(saved: straddle, screens: [builtIn, gap]) == nil)
}

@Test func corruptFramesAreNil() {
    let bad: [CGRect] = [
        CGRect(x: 100, y: 100, width: 0, height: 200),
        CGRect(x: 100, y: 100, width: 600, height: 0),
        CGRect(x: 100, y: 100, width: -600, height: 200),
        CGRect(x: 100, y: 100, width: 600, height: -200),
        CGRect(x: CGFloat.nan, y: 100, width: 600, height: 200),
        CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 200),
        CGRect(x: 100, y: CGFloat.infinity, width: 600, height: 200),
        CGRect(x: 100, y: 100, width: 600, height: CGFloat.nan),
    ]
    for r in bad { #expect(Placement.restoredFrame(saved: r, screens: [builtIn]) == nil) }
}

@Test func restoredFrameIsMostlyOnScreen() async {
    await propertyCheck(
        input: Gen.double(in: -5000...5000), Gen.double(in: -5000...5000),
        Gen.double(in: 50...3000), Gen.double(in: 50...3000), Gen.bool()
    ) { x, y, w, h, both in
        let saved = CGRect(x: x, y: y, width: w, height: h)
        let screens = both ? [builtIn, external] : [builtIn]
        if let r = Placement.restoredFrame(saved: saved, screens: screens) {
            #expect(r == saved)
            #expect(
                screens.contains {
                    let i = $0.visibleFrame.intersection(r)
                    return i.width * i.height >= 0.5 * r.width * r.height
                })
        }
    }
}

@Test func defaultFrameInsideVisibleFrame() async {
    await propertyCheck(
        input: Gen.double(in: -5000...5000), Gen.double(in: -5000...5000),
        Gen.double(in: 640...4000), Gen.double(in: 208...3000)
    ) { x, y, w, h in
        let visible = CGRect(x: x, y: y, width: w, height: h)
        let screen = ScreenInfo(frame: visible, visibleFrame: visible, isBuiltIn: true)
        #expect(visible.contains(Placement.defaultFrame(on: screen)))
    }
}
