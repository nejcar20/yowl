import Testing
import Foundation
@testable import AlarmCore

// A configuration that cannot protect anything must say so before the user
// walks away from the laptop. Discovering it by unplugging the charger and
// hearing silence is the worst possible way to find out.
@Test func noEnabledTriggersIsReportedAsUnprotected() {
    let power = FakeTrigger(id: TriggerID("power"))
    let motion = FakeTrigger(id: TriggerID("motion"))
    power.isEnabled = false
    motion.isEnabled = false
    #expect(ProtectionStatus(triggers: [power, motion]) == .nothingEnabled)
}

@Test func anEnabledTriggerThatCannotFireNowIsReported() {
    let power = FakeTrigger(id: TriggerID("power"), canFireNow: false)
    #expect(ProtectionStatus(triggers: [power]) == .nothingCanFireNow(blocked: [TriggerID("power")]))
}

@Test func oneUsableTriggerIsProtected() {
    let power = FakeTrigger(id: TriggerID("power"))
    let motion = FakeTrigger(id: TriggerID("motion"))
    motion.isEnabled = false
    #expect(ProtectionStatus(triggers: [power, motion]) == .protected)
}

// An unavailable trigger the user "enabled" must not count as protection: that
// is the two-axis rule, and this is where a user would be misled by it.
@Test func anEnabledButUnavailableTriggerIsNotProtection() {
    let motion = FakeTrigger(id: TriggerID("motion"), isAvailable: false)
    motion.isEnabled = true
    #expect(ProtectionStatus(triggers: [motion]) == .nothingEnabled)
}

@Test func protectedIsTheOnlyStatusWithoutAWarning() {
    #expect(ProtectionStatus.protected.warning == nil)
    #expect(ProtectionStatus.nothingEnabled.warning != nil)
    #expect(ProtectionStatus.nothingCanFireNow(blocked: [TriggerID("power")]).warning != nil)
}

// The shipped message named both the charger and the lid every time, joined by
// "or", so it was a guess in every case -- and at ~130 characters it was long
// enough to be clipped before the reader reached the part that mattered. What a
// blocked user needs is the one thing to do next.
@Test func aBlockedChargerSaysToPlugItIn() {
    let warning = ProtectionStatus.nothingCanFireNow(blocked: [TriggerID("power")]).warning
    #expect(warning == "Plug the charger in to arm, or switch on another trigger in Settings.")
}

@Test func aBlockedLidSaysToOpenIt() {
    let warning = ProtectionStatus.nothingCanFireNow(blocked: [TriggerID("lid")]).warning
    #expect(warning == "Open the lid further to arm, or switch on another trigger in Settings.")
}

@Test func bothBlockedNamesBoth() {
    let warning = ProtectionStatus
        .nothingCanFireNow(blocked: [TriggerID("power"), TriggerID("lid")]).warning
    #expect(warning == "Plug the charger in and open the lid further to arm, or switch on another trigger in Settings.")
}

/// A trigger this build does not know how to explain must still produce a
/// warning. Returning nil here would report the machine as protected.
@Test func anUnknownBlockedTriggerStillWarns() {
    let warning = ProtectionStatus.nothingCanFireNow(blocked: [TriggerID("teleport")]).warning
    #expect(warning != nil)
    #expect(warning?.isEmpty == false)
}

/// The blocked set carries only the triggers that are actually switched on and
/// available. A disabled trigger is not the reason arming is refused, and
/// naming it would send the user to fix the wrong thing.
@Test func onlyActiveTriggersAreReportedAsBlocked() {
    let power = FakeTrigger(id: TriggerID("power"), canFireNow: false)
    let lid = FakeTrigger(id: TriggerID("lid"), canFireNow: false)
    lid.isEnabled = false
    #expect(ProtectionStatus(triggers: [power, lid]) == .nothingCanFireNow(blocked: [TriggerID("power")]))
}
