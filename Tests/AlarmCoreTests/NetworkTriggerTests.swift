import Testing
import Foundation
@testable import AlarmCore

private func makeTrigger(_ monitor: FakeNetworkMonitor, _ clock: TestClock,
                         confirmAfter: TimeInterval = 30) -> NetworkTrigger {
    NetworkTrigger(monitor: monitor, clock: clock,
                   confirmAfter: confirmAfter, graceSeconds: 0)
}

// Carrying the laptop out of range drops the link and it stays down.
@Test func aSustainedDisconnectionFires() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    #expect(fired == nil, "must not fire the moment the link drops")
    clock.advance(by: 30)
    #expect(fired == TriggerID("network"))
}

// AP roams, DFS channel changes and router reboots all take seconds. Each one
// ending in a max-volume siren in public is not a recoverable experience.
@Test func aBriefDropDoesNotFire() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    clock.advance(by: 10)
    monitor.simulate(isLinkUp: true)
    clock.advance(by: 120)
    #expect(fired == nil)
}

// Reconnecting then dropping again must restart the window, not resume it.
@Test func reconnectingRestartsTheConfirmationWindow() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    clock.advance(by: 25)
    monitor.simulate(isLinkUp: true)
    monitor.simulate(isLinkUp: false)
    clock.advance(by: 25)
    #expect(fired == nil, "the second window must start from zero")
    clock.advance(by: 5)
    #expect(fired == TriggerID("network"))
}

// Repeated "still down" notifications must not stack windows.
@Test func repeatedDropNotificationsFireOnlyOnce() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fireCount = 0
    try trigger.start { _ in fireCount += 1 }
    for _ in 0..<10 { monitor.simulate(isLinkUp: false) }
    clock.advance(by: 60)
    #expect(fireCount == 1)
}

@Test func stayingConnectedNeverFires() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for _ in 0..<20 { monitor.simulate(isLinkUp: true) }
    clock.advance(by: 300)
    #expect(fired == nil)
}

@Test func cannotFireWhenAlreadyDisconnected() {
    let clock = TestClock()
    #expect(makeTrigger(FakeNetworkMonitor(isLinkUp: false), clock).canFireNow == false)
    #expect(makeTrigger(FakeNetworkMonitor(isLinkUp: true), clock).canFireNow == true)
}

// Pins the trigger's own teardown, not the fake's: deleting the cancellation
// from stop() must fail this.
@Test func stoppingCancelsAPendingConfirmation() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    trigger.stop()
    clock.advance(by: 120)
    #expect(fired == nil, "a window pending at stop() must not fire afterwards")
    #expect(monitor.isMonitoring == false)
}

@Test func restartingClearsAPendingWindowFromTheLastSession() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let clock = TestClock()
    let trigger = makeTrigger(monitor, clock)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    clock.advance(by: 25)
    try trigger.start { fired = $0 }
    clock.advance(by: 10)
    #expect(fired == nil, "a window from the previous session must not complete")
}

@Test func theTriggerIsUnavailableWithoutWiFi() {
    #expect(makeTrigger(FakeNetworkMonitor(isLinkUp: true, isAvailable: false),
                        TestClock()).isAvailable == false)
}
