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
