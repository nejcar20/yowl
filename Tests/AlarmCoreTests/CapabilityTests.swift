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
    await response.fire(context: AlarmContext(trigger: TriggerID("a"),
                                              firedAt: Date(timeIntervalSince1970: 0)))
    #expect(response.fireCount == 1)
    await response.reset()
    #expect(response.resetCount == 1)
}
