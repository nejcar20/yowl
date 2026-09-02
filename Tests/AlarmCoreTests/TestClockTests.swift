import Testing
import Foundation
@testable import AlarmCore

@Test func testClockDoesNotFireBeforeDeadline() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 0))
    var fired = false
    clock.schedule(after: 10) { fired = true }
    clock.advance(by: 9)
    #expect(fired == false)
}

@Test func testClockFiresAtDeadline() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 0))
    var fired = false
    clock.schedule(after: 10) { fired = true }
    clock.advance(by: 10)
    #expect(fired == true)
}

@Test func testClockDoesNotFireAfterCancel() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 0))
    var fired = false
    let work = clock.schedule(after: 10) { fired = true }
    work.cancel()
    clock.advance(by: 20)
    #expect(fired == false)
}

@Test func testClockAdvancesNow() {
    let clock = TestClock(now: Date(timeIntervalSince1970: 100))
    clock.advance(by: 5)
    #expect(clock.now == Date(timeIntervalSince1970: 105))
}
