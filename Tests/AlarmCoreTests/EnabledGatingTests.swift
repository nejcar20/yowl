import Testing
import Foundation
@testable import AlarmCore

private func makeEngine(triggers: [any Trigger], responses: [any Response],
                        clock: TestClock = TestClock(),
                        sleep: FakeSleepAssertion = FakeSleepAssertion()) -> AlarmEngine {
    let store = InMemoryPasscodeStore()
    try? store.setPasscode("1234")
    return AlarmEngine(triggers: triggers, responses: responses, clock: clock,
                       passcodes: store, sleepAssertion: sleep)
}

@Test func availableFeaturesAreEnabledByDefault() {
    #expect(FakeTrigger(id: TriggerID("power")).isEnabled == true)
    #expect(FakeResponse(identifier: "siren").isEnabled == true)
}

@Test func aDisabledResponseNeverFires() async throws {
    let trigger = FakeTrigger(id: TriggerID("power"))
    let siren = FakeResponse(identifier: "siren")
    let lock = FakeResponse(identifier: "screen-lock")
    lock.isEnabled = false
    let engine = makeEngine(triggers: [trigger], responses: [siren, lock])
    try engine.arm()
    trigger.simulateFire()
    await Task.yield(); await Task.yield()
    #expect(siren.fireCount == 1)
    #expect(lock.fireCount == 0)
}

@Test func aDisabledTriggerIsNeverStarted() throws {
    let power = FakeTrigger(id: TriggerID("power"))
    let camera = FakeTrigger(id: TriggerID("camera"))
    camera.isEnabled = false
    let engine = makeEngine(triggers: [power, camera], responses: [])
    try engine.arm()
    #expect(power.isStarted == true)
    #expect(camera.isStarted == false)
}

@Test func aDisabledTriggerCannotFireTheAlarm() throws {
    let camera = FakeTrigger(id: TriggerID("camera"))
    camera.isEnabled = false
    let power = FakeTrigger(id: TriggerID("power"))
    let engine = makeEngine(triggers: [power, camera], responses: [])
    try engine.arm()
    camera.simulateFire()
    #expect(engine.state == .armed)
}

// "Armed" must mean protected. Disabling every trigger leaves nothing that can
// fire, so arming must refuse rather than display a false sense of security.
@Test func armingWithEveryTriggerDisabledThrows() {
    let power = FakeTrigger(id: TriggerID("power"))
    power.isEnabled = false
    let sleep = FakeSleepAssertion()
    let engine = makeEngine(triggers: [power], responses: [], sleep: sleep)
    #expect(throws: AlarmEngineError.noArmableTrigger) { try engine.arm() }
    #expect(engine.state == .disarmed)
    #expect(sleep.isHeld == false)
}

// isEnabled is a *user preference* and must be re-read on every arm, unlike
// isAvailable which is a fixed property of the build and filtered once.
@Test func reenablingATriggerBetweenArmsTakesEffect() throws {
    let power = FakeTrigger(id: TriggerID("power"))
    power.isEnabled = false
    let engine = makeEngine(triggers: [power], responses: [])
    #expect(throws: AlarmEngineError.noArmableTrigger) { try engine.arm() }
    power.isEnabled = true
    try engine.arm()
    #expect(engine.state == .armed)
    #expect(power.isStarted == true)
}

// A response the user disabled before arming must not fire even if they
// re-enable it mid-alarm; but a response enabled at fire time must fire.
@Test func responseEnablementIsReadAtFireTime() async throws {
    let trigger = FakeTrigger(id: TriggerID("power"))
    let siren = FakeResponse(identifier: "siren")
    siren.isEnabled = false
    let engine = makeEngine(triggers: [trigger], responses: [siren])
    try engine.arm()
    siren.isEnabled = true
    trigger.simulateFire()
    await Task.yield(); await Task.yield()
    #expect(siren.fireCount == 1)
}
