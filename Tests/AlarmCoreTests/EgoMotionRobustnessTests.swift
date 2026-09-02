import Testing
import Foundation
@testable import AlarmCore

// The environment this app is built for is full of periodic surfaces: window
// blinds, tiled floors, brick, radiators, slatted chairs. Registration is
// ambiguous on them, and measurements showed a person walking past a striped
// background scoring HIGHER than the laptop actually being moved. These are the
// cases the original fixture was built to avoid, which is exactly why they must
// be tested.
// KNOWN LIMITATION, pinned deliberately so it cannot regress unnoticed and so
// nobody believes it is solved. On a periodic background the registration is
// ambiguous — shifting by one stripe width aligns as well as the true shift —
// so a passer-by is indistinguishable from the laptop being moved and BOTH
// score high. This test asserts the real behaviour, not the desired one.
//
// Two attempted guards were each worse than this: a shift cap blinded the
// detector to a snatch, and a half-agreement rule disabled it against a plain
// wall. Fixing this needs a different measure, not a threshold.
@Test func periodicBackgroundsCannotDistinguishAPasserByFromRealMotion() {
    let detector = EgoMotionDetector()
    let passerBy = detector.score(previous: SyntheticFrames.stripes(occluderAt: 40),
                                  current: SyntheticFrames.stripes(occluderAt: 150))
    let realMotion = detector.score(previous: SyntheticFrames.stripes(),
                                    current: SyntheticFrames.stripes(dx: 12))
    // Both score high: that is the limitation, stated as a fact.
    #expect((passerBy?.value ?? 0) > detector.threshold)
    #expect((realMotion?.value ?? 0) > detector.threshold)
}

// The same passer-by on an ordinary, non-periodic scene IS rejected, and by the
// residual rather than by any magnitude guard — which is what makes the
// limitation specific to periodic scenes rather than general.
@Test func aPasserByOnAnOrdinarySceneIsRejectedByTheResidual() {
    let detector = EgoMotionDetector()
    let score = detector.score(previous: SyntheticFrames.scene(occluderAt: 40),
                               current: SyntheticFrames.scene(occluderAt: 150))
    #expect((score?.explained ?? 0) < 0, "the warp must make the image worse, not better")
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

// Fast motion is the motion that matters. An earlier version capped plausible
// shift at 15% of frame width, which made the detector silent on a grab, a
// snatch and a laptop being carried away while still firing on a slow slide —
// exactly inverted for a theft alarm. These are the speeds that cap suppressed.
@Test func fastMotionFiresRatherThanBeingDismissed() {
    let detector = EgoMotionDetector()
    for dx in [CGFloat(50), 60, 100, 160] {
        let score = detector.score(previous: SyntheticFrames.scene(),
                                   current: SyntheticFrames.scene(dx: dx))
        #expect((score?.value ?? 0) > detector.threshold,
                "a \(Int(dx))px displacement is a snatch, not noise")
    }
}

// A grab-and-lift accelerates: the per-frame displacement grows quickly. This is
// the sequence a shift cap made invisible.
@Test func aGrabAndLiftSequenceFires() {
    let detector = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    var fired = false
    var offset: CGFloat = 0
    for delta in [CGFloat(0), 30, 60, 90, 120] {
        offset += delta
        if detector.submit(SyntheticFrames.scene(dx: offset)) { fired = true }
    }
    #expect(fired == true)
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
