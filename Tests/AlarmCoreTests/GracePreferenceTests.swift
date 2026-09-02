import Testing
import Foundation
@testable import AlarmCore

private func makeEngine(_ trigger: FakeTrigger, _ responses: [any Response],
                        clock: TestClock) -> AlarmEngine {
    let store = InMemoryPasscodeStore()
    try? store.setPasscode("1234")
    return AlarmEngine(triggers: [trigger], responses: responses, clock: clock,
                       passcodes: store, sleepAssertion: FakeSleepAssertion())
}

// The shipped default: no window at all.
@Test func zeroGraceFiresImmediately() async throws {
    let clock = TestClock()
    let trigger = FakeTrigger(id: TriggerID("power"), graceSeconds: 0)
    let siren = FakeResponse(identifier: "siren")
    let engine = makeEngine(trigger, [siren], clock: clock)
    try engine.arm()
    trigger.simulateFire()
    await Task.yield(); await Task.yield()
    #expect(engine.state == .firing(trigger: TriggerID("power")))
    #expect(siren.fireCount == 1)
}

// The slider must actually take effect without rebuilding the engine.
@Test func changingGraceOnATriggerTakesEffectOnTheNextArm() async throws {
    let clock = TestClock()
    let trigger = FakeTrigger(id: TriggerID("power"), graceSeconds: 0)
    let siren = FakeResponse(identifier: "siren")
    let engine = makeEngine(trigger, [siren], clock: clock)

    trigger.graceSeconds = 20
    try engine.arm()
    trigger.simulateFire()
    #expect(siren.fireCount == 0)
    clock.advance(by: 19)
    await Task.yield()
    #expect(siren.fireCount == 0)
    clock.advance(by: 1)
    await Task.yield(); await Task.yield()
    #expect(siren.fireCount == 1)
}

// A response that fired and was THEN disabled must still be reset, or the
// siren keeps sounding and the user's audio settings are never restored.
@Test func disablingAResponseMidAlarmStillResetsIt() async throws {
    let clock = TestClock()
    let trigger = FakeTrigger(id: TriggerID("power"), graceSeconds: 0)
    let siren = FakeResponse(identifier: "siren")
    let engine = makeEngine(trigger, [siren], clock: clock)
    try engine.arm()
    trigger.simulateFire()
    await Task.yield(); await Task.yield()
    #expect(siren.fireCount == 1)

    siren.isEnabled = false
    _ = engine.disarm(passcode: "1234")
    await Task.yield(); await Task.yield()
    #expect(siren.resetCount == 1)
}
