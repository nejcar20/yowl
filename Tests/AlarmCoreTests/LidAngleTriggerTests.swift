import Testing
import Foundation
@testable import AlarmCore

private func makeTrigger(_ sensor: FakeLidAngleSensor,
                         closingBy: Double = 8) -> LidAngleTrigger {
    LidAngleTrigger(sensor: sensor, closingByDegrees: closingBy, graceSeconds: 0)
}

// Closing the lid is the theft gesture: someone shuts the laptop to carry it.
// The angle sensor sees it degrees before the lid is shut, which is the whole
// advantage over waiting for a sleep notification that arrives too late.
@Test func closingTheLidFires() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    sensor.simulate(angle: 95)
    #expect(fired == TriggerID("lid"))
}

// Opening it further is not a theft gesture.
@Test func openingTheLidDoesNotFire() throws {
    let sensor = FakeLidAngleSensor(angle: 100)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    sensor.simulate(angle: 130)
    #expect(fired == nil)
}

// The hinge reading jitters by a degree or so while typing. Firing on that
// would make the alarm unusable at a desk.
@Test func smallJitterDoesNotFire() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for angle in [109.0, 110.0, 108.5, 111.0, 109.5] { sensor.simulate(angle: angle) }
    #expect(fired == nil)
}

// Slow closing must still fire: a careful thief does not slam the lid. The
// threshold is measured from where the lid was when arming, not frame to frame.
@Test func aSlowCloseStillFires() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for angle in stride(from: 108.0, through: 98.0, by: -2) { sensor.simulate(angle: angle) }
    #expect(fired == TriggerID("lid"))
}

// Re-arming takes the current angle as the new baseline, or arming with a
// half-closed lid would fire immediately.
@Test func restartingRebaselinesToTheCurrentAngle() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor)
    var fireCount = 0
    try trigger.start { _ in fireCount += 1 }
    sensor.simulate(angle: 90)
    #expect(fireCount == 1)

    trigger.stop()
    try trigger.start { _ in fireCount += 1 }
    // 90 is the new baseline; staying near it must not re-fire.
    sensor.simulate(angle: 88)
    #expect(fireCount == 1)
}

@Test func stoppingPreventsTheLidTriggerFiring() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    trigger.stop()
    sensor.simulate(angle: 60)
    #expect(fired == nil)
    #expect(sensor.isReading == false)
}

@Test func theTriggerIsUnavailableWithoutTheSensor() {
    #expect(makeTrigger(FakeLidAngleSensor(angle: 110, isAvailable: false)).isAvailable == false)
}

// Unlike the charger, the lid can always be closed further, so there is always
// something left to detect — except when it is already shut.
@Test func canFireNowUnlessTheLidIsAlreadyShut() {
    #expect(makeTrigger(FakeLidAngleSensor(angle: 110)).canFireNow == true)
    #expect(makeTrigger(FakeLidAngleSensor(angle: 2)).canFireNow == false)
}

// --- The paths that hid three silent-death bugs ---

// A failed read at arm time used to leave the trigger deaf for the entire
// session while the UI still said "Armed". The baseline now adopts the first
// reading that succeeds.
@Test func aFailedReadAtArmTimeDoesNotKillTheTrigger() throws {
    let sensor = FakeLidAngleSensor(angle: nil)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    sensor.simulate(angle: 110)   // sensor recovers; this becomes the baseline
    sensor.simulate(angle: 95)
    #expect(fired == TriggerID("lid"))
}

// A transient nil mid-session must be skipped, not treated as a reading.
@Test func aTransientFailedReadIsSkippedNotFatal() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    sensor.simulateReadFailure()
    sensor.simulate(angle: 95)
    #expect(fired == TriggerID("lid"), "one bad sample must not stop monitoring")
}

// Arming was permitted in a band where the fire threshold sat below the angle at
// which the lid is already shut — so the alarm could only fire after clamshell
// sleep had begun, which is the latency this trigger exists to avoid.
@Test func aLidTooShallowToFireBeforeShuttingCannotArm() {
    // shutAngle 5 + threshold 8 = 13: at 12 there is no room to fire in time.
    #expect(makeTrigger(FakeLidAngleSensor(angle: 12), closingBy: 8).canFireNow == false)
    #expect(makeTrigger(FakeLidAngleSensor(angle: 20), closingBy: 8).canFireNow == true)
}

@Test func canFireNowIsFalseWhenTheAngleCannotBeRead() {
    #expect(makeTrigger(FakeLidAngleSensor(angle: nil)).canFireNow == false)
}

// --- The threshold itself, which no test previously pinned ---

// Any value from 2 to 12 degrees passed the whole suite before this: the shipped
// number was untested across a band spanning "fires when you tilt the screen" to
// "fires only when nearly shut".
@Test func theClosingThresholdIsExactlyWhatItClaims() throws {
    let sensor = FakeLidAngleSensor(angle: 100)
    let trigger = makeTrigger(sensor, closingBy: 25)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    sensor.simulate(angle: 76)   // 24 degrees: just under
    #expect(fired == nil)
    sensor.simulate(angle: 75)   // 25 degrees: exactly at the threshold
    #expect(fired == TriggerID("lid"))
}

@Test func aNonDefaultThresholdChangesBehaviour() throws {
    let lenient = FakeLidAngleSensor(angle: 100)
    let lenientTrigger = makeTrigger(lenient, closingBy: 40)
    var lenientFired = false
    try lenientTrigger.start { _ in lenientFired = true }
    lenient.simulate(angle: 70)   // 30 degrees
    #expect(lenientFired == false, "30 degrees must not fire a 40-degree threshold")

    let strict = FakeLidAngleSensor(angle: 100)
    let strictTrigger = makeTrigger(strict, closingBy: 10)
    var strictFired = false
    try strictTrigger.start { _ in strictFired = true }
    strict.simulate(angle: 70)
    #expect(strictFired == true)
}

// Pins the trigger's own teardown rather than the fake's: deleting the baseline
// and handler reset from stop() must fail this.
@Test func stoppingClearsTheBaselineSoTheNextArmRebaselines() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor, closingBy: 30)
    var fireCount = 0
    try trigger.start { _ in fireCount += 1 }
    trigger.stop()

    // Re-arm at a much shallower angle. If stop() left the 110 baseline behind,
    // this arms against it and fires immediately on the first sample.
    sensor.simulate(angle: 60)
    try trigger.start { _ in fireCount += 1 }
    sensor.simulate(angle: 55)
    #expect(fireCount == 0, "the new baseline must be 60, not the stale 110")
}
