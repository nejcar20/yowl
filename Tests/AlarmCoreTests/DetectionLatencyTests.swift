import Testing
import Foundation
@testable import AlarmCore

/// Reported as "it takes a few seconds to register a steal".
///
/// The detector is not slow -- it costs about 10ms a frame at 320x240, so it
/// could sustain ~97fps. The delay was policy: frames arrived at 5fps and the
/// rule demanded three *consecutive* hits, so a single dip below the threshold
/// mid-grab reset the run to zero and the wait started again. A real pickup is
/// jerky, so that happened often.

/// Builds a sequence rather than single frames: motion is a *change* between
/// consecutive frames, so three identical "moved" frames contain exactly one
/// movement, not three. Each moved step shifts further; each still step holds.
private func sequence(_ moved: [Bool]) -> [GrayscaleFrame] {
    var offset = 0
    var out: [GrayscaleFrame] = [pattern(offset: 0)]
    for step in moved {
        if step { offset += 9 }
        out.append(pattern(offset: offset))
    }
    return out
}

private func pattern(offset: Int) -> GrayscaleFrame {
    var px = [UInt8](repeating: 0, count: 320 * 240)
    for y in 0..<240 {
        for x in 0..<320 {
            let sx = (x + offset) % 320
            px[y * 320 + x] = UInt8(truncatingIfNeeded: (sx &* 7) ^ (y &* 13))
        }
    }
    return GrayscaleFrame(width: 320, height: 240, pixels: px)
}

private func feed(_ d: EgoMotionDetector, _ moved: [Bool]) -> Bool {
    var fired = false
    for f in sequence(moved) where d.submit(f) { fired = true }
    return fired
}

/// Three clean hits still fire, as before.
@Test func sustainedMovementFires() {
    let d = EgoMotionDetector(threshold: 0.005, hitsRequired: 3, window: 5)
    #expect(feed(d, [true, true, true]))
}

/// The fix: one frame dipping below the threshold must not throw the evidence
/// away. Three hits inside a five-frame window is still movement.
@Test func aSingleDipDoesNotRestartTheCount() {
    let d = EgoMotionDetector(threshold: 0.005, hitsRequired: 3, window: 5)
    #expect(feed(d, [true, true, false, true]))
}

/// But hits spread thinly are not movement, or a busy café fires eventually.
@Test func hitsSpreadBeyondTheWindowDoNotFire() {
    let d = EgoMotionDetector(threshold: 0.005, hitsRequired: 3, window: 5)
    #expect(feed(d, [true, false, false, false, false,
                     true, false, false, false, false,
                     true, false, false, false, false]) == false)
}

/// A still camera never fires, however long it runs.
@Test func stillnessNeverFires() {
    let d = EgoMotionDetector(threshold: 0.005, hitsRequired: 3, window: 5)
    #expect(feed(d, Array(repeating: false, count: 40)) == false)
}
