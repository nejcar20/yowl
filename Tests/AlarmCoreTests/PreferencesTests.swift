import Testing
import Foundation
@testable import AlarmCore

// A feature the user has never touched should be on: someone who never opens
// settings must get the most protection, not the least.
@Test func unsetFeatureDefaultsToEnabled() {
    #expect(InMemoryPreferences().isEnabled("siren") == true)
}

@Test func disablingAFeaturePersists() {
    let prefs = InMemoryPreferences()
    prefs.setEnabled(false, for: "screen-lock")
    #expect(prefs.isEnabled("screen-lock") == false)
    #expect(prefs.isEnabled("siren") == true)
}

@Test func reenablingAFeatureWorks() {
    let prefs = InMemoryPreferences()
    prefs.setEnabled(false, for: "siren")
    prefs.setEnabled(true, for: "siren")
    #expect(prefs.isEnabled("siren") == true)
}

// Zero grace is the shipped default: the siren fires the instant the charger
// goes, with no window for a thief to find the app and quit it.
@Test func graceDefaultsToZero() {
    #expect(InMemoryPreferences().graceSeconds == 0)
}

@Test func graceRoundTrips() {
    let prefs = InMemoryPreferences()
    prefs.graceSeconds = 15
    #expect(prefs.graceSeconds == 15)
}

@Test func graceIsClampedToTheAllowedRange() {
    let prefs = InMemoryPreferences()
    prefs.graceSeconds = -5
    #expect(prefs.graceSeconds == 0)
    prefs.graceSeconds = 999
    #expect(prefs.graceSeconds == 60)
}
