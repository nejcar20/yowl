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

@Test func disarmingDuringGraceCancelsTheAlarm() async throws {
    let rig = makeRig(graceSeconds: 10)
    try rig.engine.arm()
    rig.trigger.simulateFire()
    #expect(rig.engine.disarm(passcode: "1234") == true)
    rig.clock.advance(by: 30)
    await Task.yield()
    #expect(rig.siren.fireCount == 0)
    #expect(rig.engine.state == .disarmed)
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
