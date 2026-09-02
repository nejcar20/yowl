import Testing
import Foundation
@testable import AlarmCore

@Test func firesWhenACIsDisconnected() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 10)
    var fired: TriggerID?
    try? trigger.start { fired = $0 }
    monitor.simulateChange(isOnAC: false)
    #expect(fired == TriggerID("power"))
}

@Test func doesNotFireWhenACIsConnected() {
    let monitor = FakePowerSourceMonitor(isOnACPower: false)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 10)
    var fired: TriggerID?
    try? trigger.start { fired = $0 }
    monitor.simulateChange(isOnAC: true)
    #expect(fired == nil)
}

// Battery-level notifications repeat constantly; only an actual AC->battery
// edge may fire, or the alarm would retrigger every few seconds.
@Test func doesNotFireOnRepeatedBatteryNotifications() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    monitor.simulateChange(isOnAC: false)
    monitor.simulateChange(isOnAC: false)
    monitor.simulateChange(isOnAC: false)
    #expect(fireCount == 1)
}

@Test func firesAgainAfterReconnectAndDisconnect() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    monitor.simulateChange(isOnAC: false)
    monitor.simulateChange(isOnAC: true)
    monitor.simulateChange(isOnAC: false)
    #expect(fireCount == 2)
}

// Arming on battery must not instantly fire.
@Test func armingWhileAlreadyOnBatteryDoesNotFire() {
    let monitor = FakePowerSourceMonitor(isOnACPower: false)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    #expect(fireCount == 0)
}

@Test func stoppingPreventsFurtherFiring() {
    let monitor = FakePowerSourceMonitor(isOnACPower: true)
    let trigger = PowerTrigger(monitor: monitor, graceSeconds: 0)
    var fireCount = 0
    try? trigger.start { _ in fireCount += 1 }
    trigger.stop()
    monitor.simulateChange(isOnAC: false)
    #expect(fireCount == 0)
}

@Test func powerTriggerIsAlwaysAvailable() {
    let trigger = PowerTrigger(monitor: FakePowerSourceMonitor(isOnACPower: true),
                               graceSeconds: 0)
    #expect(trigger.isAvailable == true)
}
