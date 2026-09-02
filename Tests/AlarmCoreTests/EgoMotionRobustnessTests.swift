import Testing
import Foundation
@testable import AlarmCore

// The environment this app is built for is full of periodic surfaces: window
// blinds, tiled floors, brick, radiators, slatted chairs. Registration is
// ambiguous on them, and measurements showed a person walking past a striped
// background scoring HIGHER than the laptop actually being moved. These are the
// cases the original fixture was built to avoid, which is exactly why they must
// be tested.
@Test func aPersonWalkingPastStripesDoesNotFire() {
    let detector = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    var fired = false
    for x in stride(from: CGFloat(0), to: 250, by: 25) {
        if detector.submit(SyntheticFrames.stripes(occluderAt: x)) { fired = true }
    }
    #expect(fired == false)
}

@Test func aPersonWalkingPastStripesScoresBelowThreshold() {
    let detector = EgoMotionDetector()
    let score = detector.score(previous: SyntheticFrames.stripes(occluderAt: 40),
                               current: SyntheticFrames.stripes(occluderAt: 150))
    #expect((score?.value ?? 1) <= detector.threshold)
}

// A dark room, or the lid part-closed: registration returns garbage and the
// residual is averaged over a sliver of the frame. Sensor noise alone was
// enough to complete a three-frame run and fire the siren.
@Test func aDarkNoisySceneDoesNotFire() {
    let detector = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    var fired = false
    for seed in UInt64(1)...10 {
        if detector.submit(SyntheticFrames.flat(seed: seed)) { fired = true }
    }
    #expect(fired == false)
}

@Test func aFeaturelessSceneScoresQuiet() {
    let detector = EgoMotionDetector()
    let score = detector.score(previous: SyntheticFrames.flat(seed: 1),
                               current: SyntheticFrames.flat(seed: 2))
    #expect((score?.value ?? 1) <= detector.threshold)
}

// A shift larger than a real camera can produce between frames at 5 fps is
// registration failure, not motion. Accepting it is what let a 215px bogus
// shift dominate the score.
@Test func animplausiblyLargeShiftIsTreatedAsRegistrationFailure() {
    let detector = EgoMotionDetector()
    // Half the frame width in 200ms is not a hand nudge.
    let score = detector.score(previous: SyntheticFrames.scene(),
                               current: SyntheticFrames.scene(dx: 200))
    #expect((score?.value ?? 1) <= detector.threshold)
}

// The guards must not break the case the feature exists for.
@Test func genuineMotionStillFiresWithTheGuardsInPlace() {
    let detector = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    _ = detector.submit(SyntheticFrames.scene())
    _ = detector.submit(SyntheticFrames.scene(dx: 10))
    _ = detector.submit(SyntheticFrames.scene(dx: 20))
    #expect(detector.submit(SyntheticFrames.scene(dx: 30)) == true)
}

// A frame pair that cannot be scored must clear the run, or a stalled sequence
// can be completed by a single later hit minutes afterwards.
@Test func anUnscorableFrameClearsTheConsecutiveRun() {
    let detector = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    _ = detector.submit(SyntheticFrames.scene())
    _ = detector.submit(SyntheticFrames.scene(dx: 10))
    _ = detector.submit(SyntheticFrames.scene(dx: 20))
    // A mismatched frame size cannot be scored at all.
    _ = detector.submit(GrayscaleFrame(width: 8, height: 8, pixels: [UInt8](repeating: 0, count: 64)))
    _ = detector.submit(SyntheticFrames.scene(dx: 30))
    #expect(detector.submit(SyntheticFrames.scene(dx: 40)) == false)
}
