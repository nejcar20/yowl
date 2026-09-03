import Testing
import Foundation
@testable import AlarmCore

private func makeTrigger(_ monitor: FakeNetworkMonitor,
                         confirmAfter: Int = 2) -> NetworkTrigger {
    NetworkTrigger(monitor: monitor, consecutiveDropsRequired: confirmAfter, graceSeconds: 0)
}

// Carrying the laptop out of range drops the Wi-Fi link. Deliberately does NOT
// read the network name: that needs Location permission, and knowing the name
// only distinguishes "moved to another network", which is not the theft case.
@Test func losingTheLinkFires() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let trigger = makeTrigger(monitor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: false)
    #expect(fired == TriggerID("network"))
}

// Wi-Fi blips constantly. One dropped sample must not fire, or the alarm is
// unusable on any real network.
@Test func aSingleBlipDoesNotFire() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let trigger = makeTrigger(monitor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: true)
    #expect(fired == nil)
}

@Test func aRecoveredLinkResetsTheRun() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let trigger = makeTrigger(monitor, confirmAfter: 3)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: true)
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: false)
    #expect(fired == nil)
}

@Test func stayingConnectedNeverFires() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let trigger = makeTrigger(monitor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    for _ in 0..<20 { monitor.simulate(isLinkUp: true) }
    #expect(fired == nil)
}

// Arming while already disconnected has nothing left to detect, exactly like
// the charger trigger with the charger already out.
@Test func cannotFireWhenAlreadyDisconnected() {
    #expect(makeTrigger(FakeNetworkMonitor(isLinkUp: false)).canFireNow == false)
    #expect(makeTrigger(FakeNetworkMonitor(isLinkUp: true)).canFireNow == true)
}

@Test func stoppingPreventsTheNetworkTriggerFiring() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let trigger = makeTrigger(monitor)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    trigger.stop()
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: false)
    #expect(fired == nil)
    #expect(monitor.isMonitoring == false)
}

@Test func restartingClearsAPartialRun() throws {
    let monitor = FakeNetworkMonitor(isLinkUp: true)
    let trigger = makeTrigger(monitor, confirmAfter: 3)
    var fired: TriggerID?
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    monitor.simulate(isLinkUp: false)
    trigger.stop()
    try trigger.start { fired = $0 }
    monitor.simulate(isLinkUp: false)
    #expect(fired == nil, "a run from the previous session must not be completed by one new drop")
}

@Test func theTriggerIsUnavailableWithoutWiFi() {
    #expect(makeTrigger(FakeNetworkMonitor(isLinkUp: true, isAvailable: false)).isAvailable == false)
}
