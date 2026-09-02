// Tests/AlarmCoreTests/EgoMotionDetectorTests.swift
import Testing
import Foundation
@testable import AlarmCore

private let detector = { EgoMotionDetector() }

// Verified against the real Vision framework: a genuinely moved camera yields a
// warp that explains almost the whole frame.
@Test func aMovedCameraScoresPositive() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(),
                                      current: SyntheticFrames.scene(dx: 12)))
    #expect((score?.value ?? 0) > 0.01)
    #expect((score?.explained ?? 0) > 0.8)
}

// THE test. Registration returns a large spurious shift for a passerby (~170px
// measured); only the residual check rejects it. If this passes while
// `explained` is removed from the score, the detector is useless in a cafe.
@Test func aPersonWalkingPastScoresBelowZero() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(occluderAt: 40),
                                      current: SyntheticFrames.scene(occluderAt: 150)))
    #expect((score?.value ?? 1) <= 0)
    #expect((score?.shift ?? 0) > 20, "expected a large spurious shift; if this is small the fixture is not exercising the real failure mode")
}

// Asserts on `explained`, not just `value`: with shift ~0 the value is zero
// whatever `explained` does, so a value-only assertion passes even with the
// discriminator deleted and proves nothing.
@Test func aGlobalLightingChangeIsNotExplainedByAnyShift() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(),
                                      current: SyntheticFrames.scene(brightness: 0.18)))
    #expect(abs(score?.value ?? 1) < 0.001)
    #expect((score?.explained ?? 1) <= 0.01,
            "a uniform brightness change is not a translation and no warp should explain it")
}

@Test func identicalFramesScoreZero() {
    let d = detector()
    let frame = SyntheticFrames.scene()
    let score = try? #require(d.score(previous: frame, current: frame))
    #expect(abs(score?.value ?? 1) < 0.001)
}

// A small real movement must still register: someone nudging the laptop.
// `> 0` would pass at 1e-9, i.e. for a score that could never fire. The margin
// is the point: a 3px nudge must clear the firing threshold.
@Test func aSmallCameraMovementClearsTheFiringThreshold() {
    let d = detector()
    let score = try? #require(d.score(previous: SyntheticFrames.scene(),
                                      current: SyntheticFrames.scene(dx: 3)))
    #expect((score?.value ?? 0) > d.threshold)
}

// Single-frame noise must not fire the alarm; K consecutive frames must.
@Test func oneMovedFrameDoesNotFire() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    #expect(d.submit(SyntheticFrames.scene()) == false)
    #expect(d.submit(SyntheticFrames.scene(dx: 12)) == false)
}

@Test func threeConsecutiveMovedFramesFire() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    _ = d.submit(SyntheticFrames.scene())
    #expect(d.submit(SyntheticFrames.scene(dx: 12)) == false)
    #expect(d.submit(SyntheticFrames.scene(dx: 24)) == false)
    #expect(d.submit(SyntheticFrames.scene(dx: 36)) == true)
}

// A quiet frame between moves resets the run, or noise would accumulate into
// a false alarm over minutes.
@Test func aQuietFrameResetsTheConsecutiveRun() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    _ = d.submit(SyntheticFrames.scene())
    _ = d.submit(SyntheticFrames.scene(dx: 12))
    _ = d.submit(SyntheticFrames.scene(dx: 12))   // no further movement
    _ = d.submit(SyntheticFrames.scene(dx: 24))
    #expect(d.submit(SyntheticFrames.scene(dx: 36)) == false)
}

@Test func peopleWalkingPastNeverFireHoweverManyFrames() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 3)
    var fired = false
    for x in stride(from: CGFloat(0), to: 250, by: 25) {
        if d.submit(SyntheticFrames.scene(occluderAt: x)) { fired = true }
    }
    #expect(fired == false)
}

@Test func resetClearsTheRunAndTheLastScore() {
    let d = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 2)
    _ = d.submit(SyntheticFrames.scene())
    _ = d.submit(SyntheticFrames.scene(dx: 12))
    d.reset()
    #expect(d.lastScore == nil)
    #expect(d.submit(SyntheticFrames.scene(dx: 24)) == false)
}
