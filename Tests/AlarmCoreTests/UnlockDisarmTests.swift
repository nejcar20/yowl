import Testing
import Foundation
@testable import AlarmCore

/// Unlocking the Mac is stronger authentication than a four-digit app passcode,
/// and it is authentication the user already performs. These tests pin down the
/// one thing that makes it safe to accept: it only counts while the screen lock
/// response will actually fire, so there is always a locked screen standing
/// between a thief and the silence.

private func makeEngine(hasPasscode: Bool = true,
                        screenLockAvailable: Bool = true,
                        screenLockEnabled: Bool = true)
    -> (AlarmEngine, FakeTrigger, ScreenLockResponse, InMemoryPasscodeStore) {
    let passcodes = InMemoryPasscodeStore()
    if hasPasscode { try? passcodes.setPasscode("1234") }
    let trigger = FakeTrigger(id: TriggerID("power"))
    let lock = ScreenLockResponse(locker: FakeScreenLocker(isAvailable: screenLockAvailable))
    lock.isEnabled = screenLockEnabled
    let engine = AlarmEngine(triggers: [trigger],
                             responses: [lock],
                             clock: TestClock(),
                             passcodes: passcodes,
                             sleepAssertion: FakeSleepAssertion())
    return (engine, trigger, lock, passcodes)
}

@Test func unlockingTheScreenDisarms() throws {
    let (engine, _, _, _) = makeEngine()
    try engine.arm()
    #expect(engine.state == .armed)

    #expect(engine.disarmByScreenUnlock() == true)

    #expect(engine.state == .disarmed)
}

/// The whole safety argument. With the screen lock switched off, an alarm fires
/// on a Mac that is never locked -- so an unlock event cannot mean "the owner
/// authenticated", and accepting it would silence the siren for free.
@Test func unlockingDoesNotDisarmWhenTheScreenLockIsSwitchedOff() throws {
    let (engine, _, _, _) = makeEngine(screenLockEnabled: false)
    try engine.arm()

    #expect(engine.disarmByScreenUnlock() == false)
    #expect(engine.state == .armed)
}

/// Same argument for a Mac where the locker is not available at all.
@Test func unlockingDoesNotDisarmWhenTheLockerIsUnavailable() throws {
    let (engine, _, _, _) = makeEngine(screenLockAvailable: false)
    try engine.arm()

    #expect(engine.disarmByScreenUnlock() == false)
    #expect(engine.state == .armed)
}

/// With the screen lock doing the authenticating, a passcode is no longer a
/// precondition for arming -- which is what removes the setup step nobody
/// should have to complete before the app does anything.
@Test func armingNeedsNoPasscodeWhenTheScreenWillLock() throws {
    let (engine, _, _, _) = makeEngine(hasPasscode: false)

    try engine.arm()

    #expect(engine.state == .armed)
}

/// But with no lock and no passcode there is no way to stop a siren, so arming
/// must still be refused.
@Test func armingWithoutAPasscodeOrAScreenLockIsRefused() {
    let (engine, _, _, _) = makeEngine(hasPasscode: false, screenLockEnabled: false)

    #expect(throws: AlarmEngineError.noPasscodeSet) { try engine.arm() }
}

/// The passcode route has to keep working: it is the fallback for exactly the
/// configuration above.
@Test func thePasscodeStillDisarms() throws {
    let (engine, _, _, _) = makeEngine(screenLockEnabled: false)
    try engine.arm()

    #expect(engine.disarm(passcode: "1234") == true)
    #expect(engine.state == .disarmed)
}

/// An unlock while nothing is armed must not be treated as a disarm that
/// succeeded -- callers use the result to decide whether to clear UI state.
@Test func unlockingWhileDisarmedChangesNothing() {
    let (engine, _, _, _) = makeEngine()

    #expect(engine.disarmByScreenUnlock() == false)
    #expect(engine.state == .disarmed)
}
