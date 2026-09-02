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

@Test func forceThrowsWhenShouldFailForceIsSet() {
    let audio = FakeAudioOutputControl(
        state: AudioOutputState(deviceID: 1, volume: 0.2, muted: true))
    audio.shouldFailForce = true
    #expect(throws: AudioOutputError.self) {
        try audio.forceMaxVolumeOnBuiltInSpeakers()
    }
}

// Per-channel volume capture and restore: verify the contract with the Fake.
// The real CoreAudioOutputControl path is untestable; this exercises only
// the protocol contract and state-management logic.
@Test func perChannelVolumesRoundTrip() {
    let channelVols: [UInt32: Float] = [1: 0.3, 2: 0.7]
    let original = AudioOutputState(deviceID: 1, volume: 0.3, muted: false,
                                    channelVolumes: channelVols)
    let audio = FakeAudioOutputControl(state: original)
    let captured = audio.currentState()
    try? audio.forceMaxVolumeOnBuiltInSpeakers()
    audio.restore(captured)
    #expect(audio.state == original)
    #expect(audio.state.channelVolumes == channelVols)
}
