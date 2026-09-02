import Testing
@testable import AlarmCore

@Test func acquiringHoldsTheAssertion() throws {
    let assertion = FakeSleepAssertion()
    try assertion.acquire(reason: "armed")
    #expect(assertion.isHeld == true)
    #expect(assertion.lastReason == "armed")
}

@Test func releasingDropsTheAssertion() throws {
    let assertion = FakeSleepAssertion()
    try assertion.acquire(reason: "armed")
    assertion.release()
    #expect(assertion.isHeld == false)
}

@Test func acquiringTwiceDoesNotDoubleAcquire() throws {
    let assertion = FakeSleepAssertion()
    try assertion.acquire(reason: "armed")
    try assertion.acquire(reason: "armed")
    #expect(assertion.acquireCount == 1)
}

@Test func releasingWithoutAcquiringIsHarmless() {
    let assertion = FakeSleepAssertion()
    assertion.release()
    #expect(assertion.releaseCount == 0)
    #expect(assertion.isHeld == false)
}

// Verified grantable 2026-09-02.
@Test func realAssertionCanBeAcquiredAndReleased() throws {
    let assertion = IOKitSleepAssertion()
    try assertion.acquire(reason: "unit test")
    #expect(assertion.isHeld == true)
    assertion.release()
    #expect(assertion.isHeld == false)
}
