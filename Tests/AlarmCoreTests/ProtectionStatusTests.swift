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
    #expect(ProtectionStatus(triggers: [power]) == .nothingCanFireNow)
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
    #expect(ProtectionStatus.nothingCanFireNow.warning != nil)
}
