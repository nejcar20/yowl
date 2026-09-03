import Testing
import Foundation
@testable import AlarmCore

// Starting a session must not switch evidence capture off. It did: `start()`
// assigned a fresh CaptureState and the memberwise init defaulted retainStills
// back to false, so no photograph was ever taken. Nothing caught it because
// start() throws before this point without a camera, so no test reached it.
@Test func startingASessionPreservesTheUsersEvidenceSetting() {
    var state = CameraFrameSource.CaptureState()
    state.retainStills = true
    CameraFrameSource.resetForNewSession(&state)
    #expect(state.retainStills == true, "a new session must not switch off evidence capture")
    #expect(state.isRunning == true)
}

// The per-session fields must still be cleared, or the run-up from a previous
// arming would be saved as though it preceded this one.
@Test func startingASessionClearsTheRunUpFromTheLastOne() {
    var state = CameraFrameSource.CaptureState()
    state.retainStills = true
    state.buffer = [TimestampedStill(jpeg: Data([1]), capturedAt: Date())]
    state.latestStill = Data([9])
    state.lastDelivery = Date()

    CameraFrameSource.resetForNewSession(&state)
    #expect(state.buffer.isEmpty)
    #expect(state.latestStill == nil)
    #expect(state.lastDelivery == .distantPast)
}

@Test func evidenceCaptureStaysOffWhenItWasOff() {
    var state = CameraFrameSource.CaptureState()
    CameraFrameSource.resetForNewSession(&state)
    #expect(state.retainStills == false)
}
