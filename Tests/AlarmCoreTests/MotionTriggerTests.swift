// Tests/AlarmCoreTests/MotionTriggerTests.swift
import Testing
import Foundation
@testable import AlarmCore

private func makeTrigger(_ source: FakeFrameSource,
                         required: Int = 3) -> MotionTrigger {
    MotionTrigger(source: source,
                  detector: EgoMotionDetector(threshold: 0.005,
                                              consecutiveFramesRequired: required),
                  graceSeconds: 0)
}

@Test func sustainedCameraMotionFiresTheTrigger() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for dx in stride(from: CGFloat(0), through: 48, by: 12) {
        source.emit(SyntheticFrames.scene(dx: dx))
    }
    #expect(fired == TriggerID("motion"))
}

@Test func peopleWalkingPastNeverFireTheTrigger() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for x in stride(from: CGFloat(0), to: 250, by: 25) {
        source.emit(SyntheticFrames.scene(occluderAt: x))
    }
    #expect(fired == nil)
}

@Test func stoppingHaltsTheSourceAndPreventsFiring() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    trigger.stop()
    #expect(source.isRunning == false)
    for dx in stride(from: CGFloat(0), through: 48, by: 12) {
        source.emit(SyntheticFrames.scene(dx: dx))
    }
    #expect(fired == nil)
}

// Re-arming must start from a clean slate: leftover frames from the previous
// session would let a single new frame complete an old run.
@Test func restartingResetsTheDetector() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fireCount = 0
    try trigger.start { _ in fireCount += 1 }
    source.emit(SyntheticFrames.scene())
    source.emit(SyntheticFrames.scene(dx: 12))
    // Restart WITHOUT stopping: stop() also resets, so stopping first would let
    // this pass even if start() never reset anything.
    try trigger.start { _ in fireCount += 1 }
    source.emit(SyntheticFrames.scene(dx: 24))
    #expect(fireCount == 0)
}

@Test func theTriggerIsUnavailableWhenTheCameraIs() {
    let trigger = makeTrigger(FakeFrameSource(isAvailable: false))
    #expect(trigger.isAvailable == false)
}

// Motion can always fire: unlike the charger, it needs no prior state.
@Test func theTriggerCanAlwaysFireNow() {
    #expect(makeTrigger(FakeFrameSource()).canFireNow == true)
}

// Calibration and arming both hold the camera; a calibration session left
// running would hold it open while the alarm needs it.
@Test func calibrationDeliversScores() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var scores: [MotionScore] = []
    try trigger.startCalibration { scores.append($0) }
    for dx in stride(from: CGFloat(0), through: 48, by: 12) {
        source.emit(SyntheticFrames.scene(dx: dx))
    }
    #expect(scores.count >= 3)
}

// Calibrating while armed would silently replace the firing handler and turn
// the alarm off with no error and no state change. The previous version of this
// test called stop() first, which set the handler to nil and made "did not
// fire" true for free.
@Test func calibrationIsRefusedWhileArmed() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    var fired = false
    try trigger.start { _ in fired = true }
    #expect(throws: MotionTriggerError.armed) {
        try trigger.startCalibration { _ in }
    }
    // The alarm still works: calibration did not steal the handler.
    for dx in stride(from: CGFloat(0), through: 48, by: 12) {
        source.emit(SyntheticFrames.scene(dx: dx))
    }
    #expect(fired == true)
}

@Test func stoppingCalibrationReleasesTheCamera() throws {
    let source = FakeFrameSource()
    let trigger = makeTrigger(source)
    try trigger.startCalibration { _ in }
    #expect(source.isRunning == true)
    trigger.stopCalibration()
    #expect(source.isRunning == false)
}

// The engine filters availability once at construction, so a trigger that
// re-reads it live gets stranded: a Mac launching with camera access denied
// dropped motion permanently, and granting access afterwards could not bring it
// back while the toggle still read on. Capturing it at construction is what
// prevents that — and with the fake's flag as a `let` this was unobservable, so
// reverting the fix passed all 224 tests.
@Test func availabilityIsCapturedAtConstructionNotReadLive() {
    let source = FakeFrameSource(isAvailable: true)
    let trigger = makeTrigger(source)
    #expect(trigger.isAvailable == true)
    source.isAvailable = false        // as if access were revoked mid-session
    #expect(trigger.isAvailable == true, "must not change after construction")
}

@Test func aMacWithNoCameraHasNoMotionTrigger() {
    #expect(makeTrigger(FakeFrameSource(isAvailable: false)).isAvailable == false)
}
