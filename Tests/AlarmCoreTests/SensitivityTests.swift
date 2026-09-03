import Testing
import Foundation
@testable import AlarmCore

// The whole point of the live readout is that the user can see where their own
// false positives land and put the line above them. That only works if the line
// moves.
@Test func sensitivityDefaultsToTheMeasuredValue() {
    #expect(InMemoryPreferences().motionThreshold == MotionSensitivity.defaultValue)
}

@Test func sensitivityRoundTrips() {
    let prefs = InMemoryPreferences()
    prefs.motionThreshold = 0.02
    #expect(prefs.motionThreshold == 0.02)
}

@Test func sensitivityIsClampedToTheUsableRange() {
    let prefs = InMemoryPreferences()
    prefs.motionThreshold = -1
    #expect(prefs.motionThreshold == MotionSensitivity.minimum)
    prefs.motionThreshold = 99
    #expect(prefs.motionThreshold == MotionSensitivity.maximum)
}

// A threshold change must take effect without rebuilding the detector, or the
// slider would only apply after a relaunch.
@Test func raisingTheThresholdStopsAMovementFiring() {
    let detector = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 2)
    _ = detector.submit(SyntheticFrames.scene())
    #expect(detector.submit(SyntheticFrames.scene(dx: 3)) == false)
    // A 3px move measures ~0.0094, so it clears 0.005 but not 0.05.
    let sensitive = EgoMotionDetector(threshold: 0.005, consecutiveFramesRequired: 1)
    _ = sensitive.submit(SyntheticFrames.scene())
    #expect(sensitive.submit(SyntheticFrames.scene(dx: 3)) == true)

    sensitive.threshold = 0.05
    sensitive.reset()
    _ = sensitive.submit(SyntheticFrames.scene())
    #expect(sensitive.submit(SyntheticFrames.scene(dx: 3)) == false,
            "raising the threshold must silence a movement that previously fired")
}

@Test func loweringTheThresholdMakesASmallerMovementFire() {
    let detector = EgoMotionDetector(threshold: 0.05, consecutiveFramesRequired: 1)
    _ = detector.submit(SyntheticFrames.scene())
    #expect(detector.submit(SyntheticFrames.scene(dx: 3)) == false)

    detector.threshold = 0.002
    detector.reset()
    _ = detector.submit(SyntheticFrames.scene())
    #expect(detector.submit(SyntheticFrames.scene(dx: 3)) == true)
}

// The slider is presented as sensitivity, which runs the opposite way to the
// threshold it sets: more sensitive means a lower bar.
@Test func sensitivityIsTheInverseOfTheThreshold() {
    // A log/exp round trip is not bit-exact; asserting equality would be
    // asserting something about floating point, not about sensitivity.
    #expect(abs(MotionSensitivity.threshold(forSensitivity: 1.0) - MotionSensitivity.minimum) < 1e-9)
    #expect(abs(MotionSensitivity.threshold(forSensitivity: 0.0) - MotionSensitivity.maximum) < 1e-9)
    let mid = MotionSensitivity.threshold(forSensitivity: 0.5)
    #expect(mid > MotionSensitivity.minimum && mid < MotionSensitivity.maximum)
}

@Test func sensitivityAndThresholdRoundTripThroughEachOther() {
    for sensitivity in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let threshold = MotionSensitivity.threshold(forSensitivity: sensitivity)
        let back = MotionSensitivity.sensitivity(forThreshold: threshold)
        #expect(abs(back - sensitivity) < 0.001)
    }
}
