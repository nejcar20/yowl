import Testing
import Foundation
@testable import AlarmCore

@Test func forcingSetsFullVolumeAndUnmutes() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.2, muted: true))
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    #expect(audio.state.volume == 1.0)
    #expect(audio.state.muted == false)
}

@Test func restoringPutsBackTheCapturedState() {
    let original = AudioOutputState(deviceID: 1, volume: 0.2, muted: true)
    let audio = FakeAudioOutputControl(state: original)
    let captured = audio.currentState()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    audio.restore(captured)
    #expect(audio.state == original)
}

// The state captured before forcing must be the pre-force state, or disarming
// would restore full volume and leave the user deafened.
@Test func capturedStateIsUnaffectedByLaterForcing() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.35, muted: false))
    let captured = audio.currentState()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    #expect(captured.volume == 0.35)
}

@Test func forcingIsIdempotent() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.2, muted: true))
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    #expect(audio.forceCount == 2)
    #expect(audio.state.volume == 1.0)
}

@Test func restoreReturnsSuccessOnHappyPath() {
    let original = AudioOutputState(deviceID: 1, volume: 0.5, muted: false)
    let audio = FakeAudioOutputControl(state: original)
    let result = audio.restore(original)
    #expect(result == true)
}

@Test func restoreReturnsFalseWhenFailing() {
    let original = AudioOutputState(deviceID: 1, volume: 0.5, muted: false)
    let audio = FakeAudioOutputControl(state: original)
    audio.shouldFailRestore = true
    let result = audio.restore(original)
    #expect(result == false)
    // But state should still be updated (attempt all steps, don't abort early)
    #expect(audio.state == original)
}
