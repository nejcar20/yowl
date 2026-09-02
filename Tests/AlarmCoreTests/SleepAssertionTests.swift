import Testing
@testable import AlarmCore

@Test func acquiringHoldsTheAssertion() {
    let assertion = FakeSleepAssertion()
    assertion.acquire(reason: "armed")
    #expect(assertion.isHeld == true)
    #expect(assertion.lastReason == "armed")
}

@Test func releasingDropsTheAssertion() {
    let assertion = FakeSleepAssertion()
    assertion.acquire(reason: "armed")
    assertion.release()
    #expect(assertion.isHeld == false)
}

@Test func acquiringTwiceDoesNotDoubleAcquire() {
    let assertion = FakeSleepAssertion()
    assertion.acquire(reason: "armed")
    assertion.acquire(reason: "armed")
    #expect(assertion.acquireCount == 1)
}

@Test func releasingWithoutAcquiringIsHarmless() {
    let assertion = FakeSleepAssertion()
    assertion.release()
    #expect(assertion.releaseCount == 0)
    #expect(assertion.isHeld == false)
}

// Verified grantable 2026-09-02.
@Test func realAssertionCanBeAcquiredAndReleased() {
    let assertion = IOKitSleepAssertion()
    assertion.acquire(reason: "unit test")
    #expect(assertion.isHeld == true)
    assertion.release()
    #expect(assertion.isHeld == false)
}
