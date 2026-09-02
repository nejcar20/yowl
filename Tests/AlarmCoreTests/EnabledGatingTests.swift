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

// Enablement is read at fire time, not captured at arm time: a response
// re-enabled between arming and firing does fire.
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

// isActive is the single place the two axes combine. Every call site uses it,
// so an unavailable feature can never be switched on by a stored preference —
// which is what keeps a sandboxed build honest about what it dropped.
@Test func anUnavailableFeatureIsNeverActiveEvenWhenEnabled() {
    let response = FakeResponse(identifier: "screen-lock", isAvailable: false)
    response.isEnabled = true
    #expect(response.isActive == false)
}

@Test func anAvailableButDisabledFeatureIsNotActive() {
    let response = FakeResponse(identifier: "siren", isAvailable: true)
    response.isEnabled = false
    #expect(response.isActive == false)
}

@Test func anAvailableAndEnabledFeatureIsActive() {
    #expect(FakeResponse(identifier: "siren", isAvailable: true).isActive == true)
}

@Test func anUnavailableTriggerCannotBeArmedByEnablingIt() {
    let trigger = FakeTrigger(id: TriggerID("lid"), isAvailable: false)
    trigger.isEnabled = true
    #expect(trigger.isActive == false)
}

// Phase 1's only trigger could not fail to start, so the engine swallowed the
// error. The camera trigger genuinely can fail, and counting a trigger that
// never started would make "Armed" mean nothing is watching.
@Test func armingFailsWhenNoEnabledTriggerCanStart() {
    let failing = ThrowingTrigger(id: TriggerID("motion"))
    let sleep = FakeSleepAssertion()
    let engine = makeEngine(triggers: [failing], responses: [], sleep: sleep)
    #expect(throws: AlarmEngineError.noArmableTrigger) { try engine.arm() }
    #expect(engine.state == .disarmed)
    #expect(sleep.isHeld == false)
}

@Test func armingSucceedsWhenAtLeastOneTriggerStarts() throws {
    let failing = ThrowingTrigger(id: TriggerID("motion"))
    let working = FakeTrigger(id: TriggerID("power"))
    let engine = makeEngine(triggers: [failing, working], responses: [])
    try engine.arm()
    #expect(engine.state == .armed)
    #expect(engine.failedTriggers == ["motion"])
}

