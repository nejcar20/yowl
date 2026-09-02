import Testing
import Foundation
@testable import AlarmCore

private let t0 = Date(timeIntervalSince1970: 1000)
private let power = TriggerID("power")

@Test func armingFromDisarmedGoesToArmed() {
    #expect(reduce(.disarmed, .arm, now: t0) == .armed)
}

@Test func triggerWithGracePeriodEntersGrace() {
    let s = reduce(.armed, .triggered(power, graceSeconds: 10), now: t0)
    #expect(s == .grace(until: t0.addingTimeInterval(10), trigger: power))
}

@Test func triggerWithoutGracePeriodFiresImmediately() {
    let s = reduce(.armed, .triggered(power, graceSeconds: 0), now: t0)
    #expect(s == .firing(trigger: power))
}

@Test func graceExpiringFires() {
    let grace = AlarmState.grace(until: t0, trigger: power)
    #expect(reduce(grace, .graceExpired, now: t0) == .firing(trigger: power))
}

@Test func disarmingDuringGraceReturnsToDisarmed() {
    let grace = AlarmState.grace(until: t0, trigger: power)
    #expect(reduce(grace, .disarm, now: t0) == .disarmed)
}

@Test func disarmingWhileFiringReturnsToDisarmed() {
    #expect(reduce(.firing(trigger: power), .disarm, now: t0) == .disarmed)
}

// Triggers must be ignored when not armed, or unplugging while disarmed
// would start screaming.
@Test func triggerWhileDisarmedIsIgnored() {
    #expect(reduce(.disarmed, .triggered(power, graceSeconds: 0), now: t0) == .disarmed)
}

// A second trigger must not restart or extend an alarm already sounding.
@Test func triggerWhileFiringIsIgnored() {
    let firing = AlarmState.firing(trigger: power)
    let other = TriggerID("lid")
    #expect(reduce(firing, .triggered(other, graceSeconds: 0), now: t0) == firing)
}

@Test func armingWhileArmedIsIdempotent() {
    #expect(reduce(.armed, .arm, now: t0) == .armed)
}

// A stale timer from a cancelled grace period must not resurrect the alarm.
@Test func graceExpiredWhileArmedIsIgnored() {
    #expect(reduce(.armed, .graceExpired, now: t0) == .armed)
}

@Test func graceExpiredWhileDisarmedIsIgnored() {
    #expect(reduce(.disarmed, .graceExpired, now: t0) == .disarmed)
}

// Disarm while armed must return to disarmed.
@Test func disarmingWhileArmedReturnsToDisarmed() {
    #expect(reduce(.armed, .disarm, now: t0) == .disarmed)
}

// A second trigger arriving during the grace period must not reset or extend
// the original deadline or replace the trigger id. The alarm preserves the
// original until date and trigger that started the grace period.
@Test func triggerDuringGracePreservesOriginalDeadlineAndTrigger() {
    let grace = AlarmState.grace(until: t0.addingTimeInterval(10), trigger: power)
    let other = TriggerID("lid")
    let result = reduce(grace, .triggered(other, graceSeconds: 5), now: t0)
    #expect(result == grace)
}

// Arm arriving during grace period is ignored; alarm stays in grace.
@Test func armingDuringGraceIsIgnored() {
    let grace = AlarmState.grace(until: t0.addingTimeInterval(10), trigger: power)
    #expect(reduce(grace, .arm, now: t0) == grace)
}

// Arm arriving while alarm is firing is ignored; alarm continues sounding.
@Test func armingWhileFiringIsIgnored() {
    let firing = AlarmState.firing(trigger: power)
    #expect(reduce(firing, .arm, now: t0) == firing)
}

// A stale grace timer firing after the alarm has already started sounding
// must not affect the alarm state.
@Test func graceExpiredWhileFiringIsIgnored() {
    let firing = AlarmState.firing(trigger: power)
    #expect(reduce(firing, .graceExpired, now: t0) == firing)
}
