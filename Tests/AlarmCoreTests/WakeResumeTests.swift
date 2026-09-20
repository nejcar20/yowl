import Testing
import Foundation
@testable import AlarmCore

/// Closing the lid fully puts the Mac to sleep, and no power assertion can stop
/// that -- Apple's own header says the system "may still sleep for lid close"
/// whatever you assert, and the pmset override that used to force it is gone on
/// Apple Silicon. So the alarm cannot keep screaming through sleep.
///
/// What it must not do is stay silent afterwards. A thief who opens the lid, or
/// a Mac that wakes for any other reason, should meet the siren again.

private func makeFiringEngine()
    -> (AlarmEngine, FakeTrigger, FakeSirenPlayer, FakeScreenLocker) {
    let passcodes = InMemoryPasscodeStore()
    try? passcodes.setPasscode("1234")
    let trigger = FakeTrigger(id: TriggerID("lid"))
    let player = FakeSirenPlayer()
    let locker = FakeScreenLocker(isAvailable: true)
    let siren = SirenResponse(
        player: player,
        audio: FakeAudioOutputControl(
            state: AudioOutputState(deviceID: 1, volume: 0.3, muted: false)),
        clock: TestClock())
    let engine = AlarmEngine(triggers: [trigger],
                             responses: [siren, ScreenLockResponse(locker: locker)],
                             clock: TestClock(),
                             passcodes: passcodes,
                             sleepAssertion: FakeSleepAssertion())
    return (engine, trigger, player, locker)
}

@Test func wakingWhileStillFiringStartsTheSirenAgain() async throws {
    let (engine, trigger, player, _) = makeFiringEngine()
    try engine.arm()
    engine.handleTrigger(trigger.id, graceSeconds: 0)
    try await Task.sleep(nanoseconds: 120_000_000)
    let startsBeforeSleep = player.startCount
    #expect(startsBeforeSleep >= 1)

    // The Mac slept and came back with the alarm never disarmed.
    engine.resumeAfterWake()
    try await Task.sleep(nanoseconds: 120_000_000)

    #expect(player.startCount > startsBeforeSleep)
}

/// And it must not fire anything on a wake that follows an ordinary disarm --
/// otherwise opening the lid the next morning screams at the owner.
@Test func wakingAfterADisarmDoesNothing() async throws {
    let (engine, trigger, player, _) = makeFiringEngine()
    try engine.arm()
    engine.handleTrigger(trigger.id, graceSeconds: 0)
    try await Task.sleep(nanoseconds: 120_000_000)
    _ = engine.disarm(passcode: "1234")
    try await Task.sleep(nanoseconds: 120_000_000)
    let startsAfterDisarm = player.startCount

    engine.resumeAfterWake()
    try await Task.sleep(nanoseconds: 120_000_000)

    #expect(player.startCount == startsAfterDisarm)
    #expect(engine.state == .disarmed)
}

/// Waking while merely armed must not fire either: nothing has been triggered.
@Test func wakingWhileArmedDoesNotFire() async throws {
    let (engine, _, player, _) = makeFiringEngine()
    try engine.arm()

    engine.resumeAfterWake()
    try await Task.sleep(nanoseconds: 120_000_000)

    #expect(player.startCount == 0)
    #expect(engine.state == .armed)
}
