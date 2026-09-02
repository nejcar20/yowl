import Testing
import Foundation
@testable import AlarmCore

private struct Rig {
    let engine: AlarmEngine
    let trigger: FakeTrigger
    let siren: FakeResponse
    let unavailable: FakeResponse
    let clock: TestClock
    let sleep: FakeSleepAssertion
}

private func makeRig(graceSeconds: TimeInterval = 0, passcode: String = "1234") -> Rig {
    let trigger = FakeTrigger(id: TriggerID("power"), graceSeconds: graceSeconds)
    let siren = FakeResponse(identifier: "siren")
    let unavailable = FakeResponse(identifier: "screen-lock", isAvailable: false)
    let clock = TestClock()
    let sleep = FakeSleepAssertion()
    let store = InMemoryPasscodeStore()
    try? store.setPasscode(passcode)
    let engine = AlarmEngine(triggers: [trigger],
                             responses: [siren, unavailable],
                             clock: clock,
                             passcodes: store,
                             sleepAssertion: sleep)
    return Rig(engine: engine, trigger: trigger, siren: siren,
               unavailable: unavailable, clock: clock, sleep: sleep)
}

@Test func armingStartsTriggersAndHoldsSleepAssertion() throws {
    let rig = makeRig()
    try rig.engine.arm()
    #expect(rig.engine.state == .armed)
    #expect(rig.trigger.isStarted == true)
    #expect(rig.sleep.isHeld == true)
}

@Test func armingWithoutAPasscodeThrows() {
    let engine = AlarmEngine(triggers: [], responses: [], clock: TestClock(),
                             passcodes: InMemoryPasscodeStore(),
                             sleepAssertion: FakeSleepAssertion())
    #expect(throws: AlarmEngineError.noPasscodeSet) { try engine.arm() }
}

@Test func triggerWithoutGraceFiresResponsesImmediately() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.engine.state == .firing(trigger: TriggerID("power")))
    #expect(rig.siren.fireCount == 1)
}

@Test func unavailableResponsesAreNeverFired() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.unavailable.fireCount == 0)
}

// Trigger-side counterpart to unavailableResponsesAreNeverFired: proves the
// other half of capability gating (AlarmEngine.swift's
// `triggers.filter(\.isAvailable)`), which currently has no coverage of its
// own. This is the mechanism Phase 5's sandboxed build relies on to drop the
// lid-angle trigger the sandbox forbids.
@Test func unavailableTriggersAreNeverStartedOrAbleToFire() async throws {
    let available = FakeTrigger(id: TriggerID("power"), isAvailable: true)
    let unavailable = FakeTrigger(id: TriggerID("lid"), isAvailable: false)
    let siren = FakeResponse(identifier: "siren")
    let store = InMemoryPasscodeStore()
    try? store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [available, unavailable],
                             responses: [siren],
                             clock: TestClock(),
                             passcodes: store,
                             sleepAssertion: FakeSleepAssertion())
    try engine.arm()
    // Pins that the engine never even registered it: if gating dropped it
    // after starting it (or not at all), this would be true.
    #expect(unavailable.isStarted == false)

    unavailable.simulateFire()
    await Task.yield()
    #expect(engine.state == .armed)
    #expect(siren.fireCount == 0)
}

@Test func graceDelaysFiring() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    #expect(rig.engine.state == .grace(until: rig.clock.now.addingTimeInterval(10),
                                       trigger: TriggerID("power")))
    #expect(rig.siren.fireCount == 0)
    rig.clock.advance(by: 10)
    await Task.yield()
    #expect(rig.siren.fireCount == 1)
}

// Documents that disarming during grace returns to `.disarmed` and stays there
// as time passes. This does NOT by itself prove the grace timer was cancelled:
// the reducer's own no-op for `.graceExpired` while `.disarmed` would make this
// pass even with cancellation removed. See
// `staleGraceTimerCannotExpireALaterGracePeriod` below for the test that
// actually pins cancellation.
@Test func disarmingDuringGraceReturnsToDisarmedAndStaysThere() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    #expect(rig.engine.disarm(passcode: "1234") == true)
    rig.clock.advance(by: 30)
    await Task.yield()
    #expect(rig.siren.fireCount == 0)
    #expect(rig.engine.state == .disarmed)
}

// Pins grace-timer cancellation for real. A stale, uncancelled timer from a
// prior grace period must not be able to expire a *later* grace period early.
//
// Sequence (10s grace): arm; trigger at t=0 -> grace until t=10; disarm at
// t=1 (this is the cancellation under test); re-arm at t=1; trigger again at
// t=5 -> a new grace until t=15. Advancing to t=10 (the original, stale
// deadline) must NOT fire the siren -- if `graceWork?.cancel()` were removed
// from `disarm()`, the first timer would fire `.graceExpired` here while the
// state is genuinely `.grace` (from the second arm cycle), cutting the user's
// second disarm window short by 5 seconds. Only advancing to t=15, the real
// deadline, should fire it.
@Test func staleGraceTimerCannotExpireALaterGracePeriod() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()                 // t=0: grace until t=10
    rig.clock.advance(by: 1)                   // t=1
    #expect(rig.engine.disarm(passcode: "1234") == true)
    try rig.engine.arm()                       // re-armed at t=1
    rig.clock.advance(by: 4)                   // t=5
    rig.trigger.simulateFire()                 // grace until t=15
    rig.clock.advance(by: 5)                   // t=10: original, stale deadline
    await Task.yield()
    #expect(rig.siren.fireCount == 0)
    rig.clock.advance(by: 5)                   // t=15: the real deadline
    await Task.yield()
    #expect(rig.siren.fireCount == 1)
}

@Test func correctPasscodeStopsTheSiren() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.engine.disarm(passcode: "1234") == true)
    await Task.yield()
    #expect(rig.siren.resetCount == 1)
    #expect(rig.engine.state == .disarmed)
}

@Test func wrongPasscodeLeavesTheSirenSounding() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.engine.disarm(passcode: "wrong") == false)
    #expect(rig.engine.state == .firing(trigger: TriggerID("power")))
    #expect(rig.siren.resetCount == 0)
}

@Test func disarmingStopsTriggersAndReleasesSleepAssertion() throws {
    let rig = makeRig()
    try rig.engine.arm()
    _ = rig.engine.disarm(passcode: "1234")
    #expect(rig.trigger.isStarted == false)
    #expect(rig.sleep.isHeld == false)
}

@Test func stateChangesAreObservable() throws {
    let rig = makeRig()
    var observed: [AlarmState] = []
    rig.engine.onStateChange = { observed.append($0) }
    try rig.engine.arm()
    _ = rig.engine.disarm(passcode: "1234")
    #expect(observed == [.armed, .disarmed])
}

// Pins the whole `onResponsesFired` contract in one test, so it cannot pass
// with `onResponsesFired?()` deleted from the engine: being armed alone must
// not invoke it, it must fire exactly once per alarm, and it must fire only
// *after* every response's fire(context:) has returned. The previous pair of
// tests missed the middle assertion -- the "armed but nothing triggered" half
// passed trivially with the callback unwired.
@Test func onResponsesFiredFiresExactlyOnceAfterResponsesHaveRun() async throws {
    let rig = makeRig(graceSeconds: 0)
    var callCount = 0
    var sirenFireCountAtEachCall: [Int] = []
    rig.engine.onResponsesFired = {
        callCount += 1
        sirenFireCountAtEachCall.append(rig.siren.fireCount)
    }

    try rig.engine.arm()
    await Task.yield()
    #expect(rig.engine.state == .armed)
    #expect(callCount == 0)          // armed alone must not invoke it

    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.siren.fireCount == 1)
    #expect(callCount == 1)          // fails if `onResponsesFired?()` is deleted
    // Fails if the callback were invoked before the responses ran.
    #expect(sirenFireCountAtEachCall == [1])
}

// C2 pre-flight. PowerTrigger is edge-detected on AC->battery, so arming while
// already on battery can never fire. Arming must refuse rather than hand the
// user a shield icon and zero protection.
@Test func armingThrowsWhenNoTriggerCanFireNow() throws {
    let trigger = FakeTrigger(id: TriggerID("power"), canFireNow: false)
    let store = InMemoryPasscodeStore()
    try store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [trigger], responses: [],
                             clock: TestClock(), passcodes: store,
                             sleepAssertion: FakeSleepAssertion())
    #expect(throws: AlarmEngineError.noArmableTrigger) { try engine.arm() }
}

@Test func armingSucceedsWhenAtLeastOneTriggerCanFire() throws {
    let dead = FakeTrigger(id: TriggerID("power"), canFireNow: false)
    let live = FakeTrigger(id: TriggerID("lid"), canFireNow: true)
    let store = InMemoryPasscodeStore()
    try store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [dead, live], responses: [],
                             clock: TestClock(), passcodes: store,
                             sleepAssertion: FakeSleepAssertion())
    try engine.arm()
    #expect(engine.state == .armed)
}

// A trigger that is unavailable on this build must not satisfy the pre-flight
// either: capability filtering happens first, so only *available* triggers can
// vouch for the arm.
@Test func unavailableTriggerCannotSatisfyThePreflight() throws {
    let unavailable = FakeTrigger(id: TriggerID("lid"), isAvailable: false,
                                  canFireNow: true)
    let store = InMemoryPasscodeStore()
    try store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [unavailable], responses: [],
                             clock: TestClock(), passcodes: store,
                             sleepAssertion: FakeSleepAssertion())
    #expect(throws: AlarmEngineError.noArmableTrigger) { try engine.arm() }
}

// A refused arm must leave nothing half-configured: the pre-flight runs before
// any side effect, so no sleep assertion is held, the state is untouched, and
// no trigger was started.
@Test func failedArmLeavesNothingHalfConfigured() throws {
    let trigger = FakeTrigger(id: TriggerID("power"), canFireNow: false)
    let sleep = FakeSleepAssertion()
    let store = InMemoryPasscodeStore()
    try store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [trigger], responses: [],
                             clock: TestClock(), passcodes: store,
                             sleepAssertion: sleep)
    #expect(throws: AlarmEngineError.noArmableTrigger) { try engine.arm() }
    #expect(engine.state == .disarmed)
    #expect(sleep.isHeld == false)
    #expect(sleep.acquireCount == 0)
    #expect(trigger.isStarted == false)
}

// I1: a sleep assertion that cannot be taken is a warning, not a refusal -- a
// machine kept awake by other means is still protected -- but it must be
// visible rather than silent.
@Test func armingProceedsAndReportsWhenTheSleepAssertionFails() throws {
    let trigger = FakeTrigger(id: TriggerID("power"))
    let sleep = FakeSleepAssertion()
    sleep.shouldFailAcquire = true
    let store = InMemoryPasscodeStore()
    try store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [trigger], responses: [],
                             clock: TestClock(), passcodes: store,
                             sleepAssertion: sleep)
    try engine.arm()
    #expect(engine.state == .armed)
    #expect(trigger.isStarted == true)
    #expect(sleep.isHeld == false)
    #expect(engine.sleepAssertionFailed == true)
}

@Test func aSuccessfulArmReportsNoSleepAssertionFailure() throws {
    let rig = makeRig()
    try rig.engine.arm()
    #expect(rig.engine.sleepAssertionFailed == false)
}

// Disarming clears the warning so it cannot survive into the next arm cycle.
@Test func disarmingClearsTheSleepAssertionWarning() throws {
    let trigger = FakeTrigger(id: TriggerID("power"))
    let sleep = FakeSleepAssertion()
    sleep.shouldFailAcquire = true
    let store = InMemoryPasscodeStore()
    try store.setPasscode("1234")
    let engine = AlarmEngine(triggers: [trigger], responses: [],
                             clock: TestClock(), passcodes: store,
                             sleepAssertion: sleep)
    try engine.arm()
    #expect(engine.sleepAssertionFailed == true)
    #expect(engine.disarm(passcode: "1234") == true)
    #expect(engine.sleepAssertionFailed == false)
}

// I2: `fireResponses` spawns an unstructured Task, so a disarm can land
// between scheduling it and running it. Without the state re-check the
// disarm's `reset` Task can drain first and the fire Task would then start the
// siren *after* the reset -- state .disarmed, savedState cleared, UI showing
// "Arm", and a screaming machine with no visible way to stop it.
@Test func aDisarmBetweenSchedulingAndRunningCancelsTheFire() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()             // state -> .firing, fire Task queued
    #expect(rig.engine.state == .firing(trigger: TriggerID("power")))
    // Disarm before the fire Task has had a chance to run.
    #expect(rig.engine.disarm(passcode: "1234") == true)
    #expect(rig.engine.state == .disarmed)

    // Drain both unstructured Tasks in either order.
    for _ in 0..<8 { await Task.yield() }

    // Without the guard this is 1: the siren starts after the reset.
    #expect(rig.siren.fireCount == 0)
    #expect(rig.engine.state == .disarmed)
}

// The same interleaving, one step later: the grace timer expires and then a
// disarm lands before the fire Task runs.
@Test func aDisarmAfterGraceExpiryButBeforeTheFireTaskRunsCancelsTheFire() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    rig.clock.advance(by: 10)              // grace expires, fire Task queued
    #expect(rig.engine.disarm(passcode: "1234") == true)
    for _ in 0..<8 { await Task.yield() }
    #expect(rig.siren.fireCount == 0)
    #expect(rig.engine.state == .disarmed)
}

// Re-arming after an alarm must work, or the app is single-use.
@Test func rearmingAfterAnAlarmWorks() async throws {
    let rig = makeRig(graceSeconds: 0)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    _ = rig.engine.disarm(passcode: "1234")
    try rig.engine.arm()
    rig.trigger.simulateFire()
    await Task.yield()
    #expect(rig.siren.fireCount == 2)
}
