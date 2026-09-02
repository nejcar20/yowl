import Testing
import Foundation
@testable import AlarmCore

@Test func unavailableTriggersAreFilteredOut() {
    let available = FakeTrigger(id: TriggerID("a"), isAvailable: true)
    let missing = FakeTrigger(id: TriggerID("b"), isAvailable: false)
    let usable: [any Trigger] = [available, missing].filter(\.isAvailable)
    #expect(usable.count == 1)
    #expect(usable.first?.id == TriggerID("a"))
}

@Test func fakeTriggerReportsFiring() {
    let trigger = FakeTrigger(id: TriggerID("a"), isAvailable: true)
    var fired: TriggerID?
    try? trigger.start { fired = $0 }
    trigger.simulateFire()
    #expect(fired == TriggerID("a"))
}

@Test func fakeResponseRecordsFireAndReset() async {
    let response = FakeResponse(identifier: "siren", isAvailable: true)
    let context = AlarmContext(trigger: TriggerID("a"), firedAt: Date(timeIntervalSince1970: 0))
    await response.fire(context: context)
    #expect(response.fireCount == 1)
    #expect(response.lastContext == context)
    await response.reset()
    #expect(response.resetCount == 1)
}

@Test func fakeResponseHandlesIdempotentFire() async {
    let response = FakeResponse(identifier: "siren", isAvailable: true)
    let context1 = AlarmContext(trigger: TriggerID("a"), firedAt: Date(timeIntervalSince1970: 0))
    let context2 = AlarmContext(trigger: TriggerID("a"), firedAt: Date(timeIntervalSince1970: 1))

    await response.fire(context: context1)
    await response.fire(context: context2)
    await response.reset()

    #expect(response.fireCount == 2)
    #expect(response.lastContext == context2)
    #expect(response.resetCount == 1)
}

@Test func fakeResponseHandlesResetWithoutFire() async {
    let response = FakeResponse(identifier: "siren", isAvailable: true)
    await response.reset()

    #expect(response.resetCount == 1)
    #expect(response.fireCount == 0)
}
