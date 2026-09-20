import Testing
import Foundation
@testable import AlarmCore

/// The measured facts behind this feature: with the lid shut and the Mac held
/// awake by a deferred sleep, the output device was present, the volume read
/// 1.0, the mute flag was cleared four times a second and the engine was
/// running -- and there was no sound. The audio hardware powers down at the
/// start of the sleep transition, not the end. So the sleep has to not begin,
/// and `pmset disablesleep` is the only lever for that.

/// Not every Mac supports `disablesleep`, and pmset exits 0 for settings it
/// ignores. The app must not advertise a siren it cannot deliver on hardware
/// where the flag is inert, so success is defined as the flag having changed.
@Test func successMeansTheFlagActuallyChanged() {
    // Unprivileged, so the set cannot take -- and must be reported as failure
    // rather than as the exit status pmset happens to return.
    let p = PmsetSleepDisabler()
    #expect(p.setSleepDisabled(true) == false)
    #expect(p.sleepDisabled() == false, "nothing should have changed")
}

@Test func pmsetRefusesToDisableSleepWithoutRoot() {
    let p = PmsetSleepDisabler()
    #expect(p.isRoot == false, "the test suite must not be running as root")
    #expect(p.setSleepDisabled(true) == false)
}

/// Reading is unprivileged, so it must work and must not report nonsense.
@Test func theSleepDisabledFlagCanBeRead() {
    let p = PmsetSleepDisabler()
    let value = p.sleepDisabled()
    #expect(value != nil)
    // Nothing in this test suite turns it on, and leaving it on would mean a
    // Mac that never sleeps again.
    #expect(value == false)
}

/// The hold has to lapse on its own. A laptop that cannot sleep, shut in a bag
/// with the camera running, is a fire risk -- so the dangerous state is the one
/// that expires, and the safe state is the one that needs no action.
@Test func aHoldIsBoundedByAMaximum() {
    #expect(LidSleepSuppression.maximumHold == 60)
    // Renewal has to be comfortably inside the window, or an ordinary
    // scheduling wobble would drop the siren mid-alarm.
    #expect(LidSleepSuppression.renewInterval < LidSleepSuppression.maximumHold / 2)
}

@Test func anUnavailableSuppressorRefusesRatherThanPretending() async {
    let s = FakeLidSleepSuppressor(isAvailable: false)
    let held = await s.hold()
    #expect(held == false)
    #expect(s.isHeld == false)
}

/// The first self-test read back `false` from a set that had plainly worked.
/// pmset prints the flag padded with spaces, and the parser has to survive that
/// exactly as the real command emits it.
@Test func theFlagIsParsedFromRealPmsetOutput() {
    let sample = """
    System-wide power settings:
     SleepDisabled        1
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatemode        3
     sleep                1 (sleep prevented by powerd)
    """
    #expect(PmsetSleepDisabler.parseSleepDisabled(from: sample) == true)

    let off = " SleepDisabled        0\n sleep                1"
    #expect(PmsetSleepDisabler.parseSleepDisabled(from: off) == false)

    // Never set at all: absent means off, not unreadable.
    #expect(PmsetSleepDisabler.parseSleepDisabled(from: " sleep   1\n standby 1") == false)
}
