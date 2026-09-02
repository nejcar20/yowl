// Tests/AlarmCoreTests/ScreenLockResponseTests.swift
import Testing
import Foundation
@testable import AlarmCore

private let ctx = AlarmContext(trigger: TriggerID("power"),
                               firedAt: Date(timeIntervalSince1970: 0))

@Test func firingLocksTheScreen() async {
    let locker = FakeScreenLocker(isAvailable: true)
    let response = ScreenLockResponse(locker: locker)
    await response.fire(context: ctx)
    #expect(locker.lockCount == 1)
}

@Test func unavailableLockerMakesTheResponseUnavailable() {
    let response = ScreenLockResponse(locker: FakeScreenLocker(isAvailable: false))
    #expect(response.isAvailable == false)
}

// Under sandbox the symbol is missing; firing anyway must be a silent no-op.
@Test func firingWithUnavailableLockerDoesNothing() async {
    let locker = FakeScreenLocker(isAvailable: false)
    let response = ScreenLockResponse(locker: locker)
    await response.fire(context: ctx)
    #expect(locker.lockCount == 0)
}

// Unlocking the Mac is the disarm; there is nothing to undo.
@Test func resetDoesNotUnlock() async {
    let locker = FakeScreenLocker(isAvailable: true)
    let response = ScreenLockResponse(locker: locker)
    await response.fire(context: ctx)
    await response.reset()
    #expect(locker.lockCount == 1)
}

@Test func realLockerFindsTheSymbolOnThisMachine() {
    // Verified present 2026-09-02. Fails under sandbox, which is the point.
    #expect(LoginFrameworkScreenLocker().isAvailable == true)
}
