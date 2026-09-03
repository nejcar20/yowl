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

// Observes the trigger, not the fake: the handler is invoked directly so the
// fake's own `isReading` cannot make this pass for free. Deleting
// `onFire = nil` from stop() must fail it.
@Test func stoppingClearsTheTriggersOwnHandler() throws {
    let sensor = FakeLidAngleSensor(angle: 110)
    let trigger = makeTrigger(sensor, closingBy: 30)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    trigger.stop()
    // Delivery is asynchronous, so a callback can already be in flight when the
    // user disarms. 40 degrees is 70 below the 110 baseline: if stop() left that
    // baseline in place, this fires the alarm after the user disarmed.
    sensor.simulateCallbackInFlight(angle: 40)
    #expect(fired == nil, "a callback in flight at stop() must not fire the alarm")
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

// Arming must leave room to fire while the lid is still usefully open. Gating
// only on "not already shut" armed the trigger at angles where it could fire
// only once the lid had all but closed — by which point clamshell sleep has
// begun, which is the latency this trigger exists to avoid.
@Test func aLidTooShallowToGiveAWarningCannotArm() {
    // Firing must leave the lid at least 30 degrees open, so with a 30-degree
    // threshold the lid must start at 60 or more.
    #expect(makeTrigger(FakeLidAngleSensor(angle: 45), closingBy: 30).canFireNow == false)
    #expect(makeTrigger(FakeLidAngleSensor(angle: 59), closingBy: 30).canFireNow == false)
    #expect(makeTrigger(FakeLidAngleSensor(angle: 60), closingBy: 30).canFireNow == true)
    #expect(makeTrigger(FakeLidAngleSensor(angle: 110), closingBy: 30).canFireNow == true)
}

// A recovered reading taken mid-close must not become the baseline: that would
// silently make the trigger unfirable while it still reported armed.
@Test func aRecoveredReadingTakenMidCloseIsNotAdoptedAsTheBaseline() throws {
    let sensor = FakeLidAngleSensor(angle: nil)
    let trigger = makeTrigger(sensor, closingBy: 30)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    sensor.simulate(angle: 40)    // too shallow to be a useful baseline
    sensor.simulate(angle: 100)   // a proper one arrives
    sensor.simulate(angle: 69)    // 31 degrees of closing from 100
    #expect(fired == TriggerID("lid"))
}

// The shipped default was never constructed by any test: `makeTrigger` always
// passed an explicit value, so 30 could have been 3 and the suite stayed green.
@Test func theShippedClosingThresholdIsThirtyDegrees() {
    let trigger = LidAngleTrigger(sensor: FakeLidAngleSensor(angle: 110), graceSeconds: 0)
    #expect(trigger.closingByDegrees == 30)
    #expect(trigger.isEnabled == false, "must be opt-in: closing your own lid is ordinary")
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

